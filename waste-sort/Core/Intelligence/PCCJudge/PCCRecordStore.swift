import Foundation
import os

/// Append-only store for PCC verdict records and their crops.
///
/// Deliberately lock-guarded synchronous APIs, not an actor: `append` is called
/// from the inference queue the moment a deposit qualifies, and converting it
/// would reorder events relative to `DetectionSessionLogger` (house rule —
/// see AGENTS.md §2). All filesystem failures are logged through `AppLog`
/// and surfaced in-band; nothing throws across the boundary.
nonisolated final class PCCRecordStore: @unchecked Sendable {
    let rootURL: URL
    private let recordsURL: URL
    private let cropsDirectory: URL
    private let exportsDirectory: URL

    /// Guards every read/write below. Contention is negligible at kiosk rates.
    private let stateLock = NSLock()
    private var openRecordsFile: FileHandle?

    private static let log = AppLog.persistence

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = support.appendingPathComponent("PCCJudge", isDirectory: true)
        }
        recordsURL = self.rootURL.appendingPathComponent("records.jsonl")
        cropsDirectory = self.rootURL.appendingPathComponent("crops", isDirectory: true)
        exportsDirectory = self.rootURL.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: cropsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
    }

    deinit {
        stateLock.lock()
        try? openRecordsFile?.close()
        stateLock.unlock()
    }

    // MARK: - Writing

    /// Persists one record synchronously, writing its crop first so a record
    /// never references bytes that do not exist yet. Safe from any queue.
    func append(_ record: PCCVerdictRecord, cropJPEG: Data?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        var stored = record
        if let jpeg = cropJPEG {
            let name = "crops/\(record.id.uuidString).jpg"
            let cropURL = rootURL.appendingPathComponent(name)
            do {
                try jpeg.write(to: cropURL, options: .atomic)
                stored.cropFile = name
            } catch {
                Self.log.error("PCC judge crop write failed: \(error.localizedDescription)")
                stored.cropFile = nil
            }
        }

        guard let line = try? PCCRecordCodec.encodeLine(stored, encoder: PCCRecordCodec.makeEncoder()) else {
            Self.log.error("PCC judge record encode failed for track \(record.trackId)")
            return
        }
        if openRecordsFile == nil {
            // `try? a ?? b` never evaluates b when a throws, so the fallback
            // must live outside the try?.
            let existing = try? FileHandle(forWritingTo: recordsURL)
            openRecordsFile = existing ?? createRecordsFile()
        }
        guard let handle = openRecordsFile else {
            Self.log.error("PCC judge records file unavailable at \(self.recordsURL.path)")
            return
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data("\n".utf8))
        } catch {
            Self.log.error("PCC judge record append failed: \(error.localizedDescription)")
            try? openRecordsFile?.close()
            openRecordsFile = nil
        }
    }

    private func createRecordsFile() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: recordsURL.path) {
            FileManager.default.createFile(atPath: recordsURL.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: recordsURL)
    }

    // MARK: - Reading

    /// All records whose timestamp falls inside the interval. Corrupt lines are
    /// skipped with a log entry — one bad row never hides the rest of a day.
    func records(in interval: DateInterval) -> [PCCVerdictRecord] {
        stateLock.lock()
        try? openRecordsFile?.close()
        openRecordsFile = nil
        stateLock.unlock()

        guard let raw = FileManager.default.contents(atPath: recordsURL.path) else { return [] }
        let decoder = PCCRecordCodec.makeDecoder()
        return raw.split(separator: UInt8(ascii: "\n")).compactMap { lineBytes in
            guard let record = try? decoder.decode(PCCVerdictRecord.self, from: Data(lineBytes)) else {
                Self.log.warning("PCC judge skipped corrupt record line")
                return nil
            }
            return interval.contains(record.timestamp) ? record : nil
        }
    }

    func allRecordCount() -> Int {
        records(in: DateInterval(start: .distantPast, duration: .greatestFiniteMagnitude)).count
    }

    // MARK: - Export bookkeeping & pruning (spec FR-10)

    /// Records that any completed export manifest already protects from pruning.
    private func exportedRecordIDsLocked() -> Set<UUID> {
        // Bundles nest as exports/<stamp>/manifest.json, so scan recursively.
        let enumerator = FileManager.default.enumerator(
            at: exportsDirectory,
            includingPropertiesForKeys: nil
        )
        let manifests = (enumerator?.allObjects as? [URL]) ?? []
        var ids = Set<UUID>()
        let decoder = PCCRecordCodec.makeDecoder()
        for manifestURL in manifests where manifestURL.lastPathComponent == "manifest.json" {
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? decoder.decode(ExportManifest.self, from: data) {
                ids.formUnion(manifest.recordIds)
            }
        }
        return ids
    }

    /// Deletes records older than `now - pruneDays` unless exported, along with
    /// their crops. Runs as foreground maintenance only — never on the frame path.
    /// - Returns: number of records removed.
    @discardableResult
    func pruneOldRecords(now: Date = Date(), pruneDays: Int = WasteSortConfig.defaultPCCPruneDays) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }

        try? openRecordsFile?.close()
        openRecordsFile = nil

        let cutoff = now.addingTimeInterval(-Double(pruneDays) * 86_400)
        guard let raw = FileManager.default.contents(atPath: recordsURL.path) else { return 0 }
        let decoder = PCCRecordCodec.makeDecoder()
        let encoder = PCCRecordCodec.makeEncoder()
        let protectedIDs = exportedRecordIDsLocked()

        var kept = Data()
        var removedCrops: [String] = []
        var removedCount = 0
        for lineBytes in raw.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(PCCVerdictRecord.self, from: Data(lineBytes)) else {
                kept += Data(lineBytes) + Data("\n".utf8)
                continue
            }
            if record.timestamp < cutoff, !protectedIDs.contains(record.id) {
                removedCount += 1
                if let cropFile = record.cropFile {
                    removedCrops.append(cropFile)
                }
                continue
            }
            kept += Data(lineBytes) + Data("\n".utf8)
        }
        if removedCount > 0 {
            do {
                try kept.write(to: recordsURL, options: .atomic)
                for crop in removedCrops {
                    try? FileManager.default.removeItem(
                        at: rootURL.appendingPathComponent(crop)
                    )
                }
                Self.log.info("PCC judge pruned \(removedCount) expired records")
            } catch {
                Self.log.error("PCC judge prune rewrite failed: \(error.localizedDescription)")
            }
        }
        return removedCount
    }

    /// Manifest written next to each export bundle; also the prune-protection
    /// registry (invariant I5).
    nonisolated struct ExportManifest: Codable, Equatable, Sendable {
        var exportedAt: Date
        var rangeStart: Date
        var rangeEnd: Date
        var recordIds: [UUID]
        var schemaVersion: Int
    }

    // MARK: - Export support

    var exportsRoot: URL { exportsDirectory }
    var cropsRoot: URL { cropsDirectory }

    func makeExportManifest(
        exportedAt: Date,
        range: DateInterval,
        recordIds: [UUID]
    ) -> ExportManifest {
        ExportManifest(
            exportedAt: exportedAt,
            rangeStart: range.start,
            rangeEnd: range.end,
            recordIds: recordIds,
            schemaVersion: PCCVerdictRecord.schemaVersion
        )
    }
}
