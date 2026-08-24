import Foundation
import os

/// Session-scoped detection log. Appends JSONL while recording, then writes a Documents CSV on finish.
///
/// Thread safety: `append` is called from the YOLO inference queue while
/// `startSession`/`finishSession`/`discardSession` run on the main thread.
/// All mutable state is guarded by `stateLock`; file writes stay inline because
/// JSONL payloads are small and ordering matters more than throughput here.
final class DetectionLogStore {
    static let shared = DetectionLogStore()

    let documentsDirectory: URL
    private let supportDirectory: URL
    private let fileManager: FileManager
    private let stateLock = NSLock()

    // MARK: State guarded by stateLock
    private var meta: DetectionSessionMeta?
    private var events: [DetectionLogEvent] = []
    private var jsonlHandle: FileHandle?

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601Fractional
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Fractional
        return decoder
    }

    var isSessionActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return meta != nil
    }

    init(
        documentsDirectory: URL? = nil,
        supportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let docs = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.documentsDirectory = docs

        let support = supportDirectory ?? {
            let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return root.appendingPathComponent("DetectionLogs", isDirectory: true)
        }()
        self.supportDirectory = support
        try? fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
    }

    func startSession(id: String, startedAt: Date, filePrefix: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        discardLocked()
        let newMeta = DetectionSessionMeta(
            sessionId: id,
            sessionStartedAt: startedAt,
            filePrefix: filePrefix
        )
        meta = newMeta
        events = []

        do {
            let data = try encoder.encode(newMeta)
            try data.write(to: metaURL(for: id), options: .atomic)
        } catch {
            AppLog.persistence.error("Failed to write session meta \(id): \(error.localizedDescription)")
        }

        let jsonl = jsonlURL(for: id)
        if !fileManager.createFile(atPath: jsonl.path, contents: nil) {
            AppLog.persistence.error("Failed to create JSONL at \(jsonl.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: jsonl)
            try handle.seekToEnd()
            jsonlHandle = handle
        } catch {
            AppLog.persistence.error("JSONL handle open failed for \(id): \(error.localizedDescription)")
        }
    }

    func append(_ event: DetectionLogEvent) {
        stateLock.lock()
        guard meta != nil else {
            stateLock.unlock()
            return
        }
        events.append(event)

        var payload: Data?
        do {
            var line = String(data: try encoder.encode(event), encoding: .utf8) ?? ""
            line.append("\n")
            payload = line.data(using: .utf8)
        } catch {
            AppLog.persistence.error("JSONL encode failed: \(error.localizedDescription)")
        }
        let handle = jsonlHandle
        stateLock.unlock()

        // Write outside the lock: FileHandle.write is itself synchronized and
        // single-consumer here (only this method touches the handle), so
        // ordering is preserved by call order on the inference queue.
        if let payload {
            do {
                try handle?.write(contentsOf: payload)
                try handle?.synchronize()
            } catch {
                AppLog.persistence.error("JSONL write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Writes Documents CSV (header-only when no events) and clears the active session.
    @discardableResult
    func finishSession() -> URL? {
        stateLock.lock()
        guard let currentMeta = meta else {
            stateLock.unlock()
            return nil
        }
        closeJSONLLocked()
        let finishedEvents = events
        self.meta = nil
        self.events = []
        stateLock.unlock()

        let url = writeCSV(events: finishedEvents, filePrefix: currentMeta.filePrefix)
        deleteSessionFiles(id: currentMeta.sessionId)
        return url
    }

    /// Drops an in-progress session without writing a CSV (failed recording start).
    func discardSession() {
        stateLock.lock()
        defer { stateLock.unlock() }
        discardLocked()
    }

    /// Turns leftover JSONL sessions into Documents CSVs (crash / force-quit recovery).
    @discardableResult
    func recoverLeftoverSessions() -> [URL] {
        guard !isSessionActive else { return [] }

        let listed = (try? fileManager.contentsOfDirectory(
            at: supportDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let metaFiles = listed.filter { $0.pathExtension.lowercased() == "json" }
        var written: [URL] = []
        for metaFile in metaFiles {
            guard let data = try? Data(contentsOf: metaFile),
                  let leftover = try? decoder.decode(DetectionSessionMeta.self, from: data)
            else {
                AppLog.persistence.error("Discarding unreadable leftover meta \(metaFile.lastPathComponent)")
                try? fileManager.removeItem(at: metaFile)
                continue
            }
            let jsonl = jsonlURL(for: leftover.sessionId)
            let recoveredEvents = loadEvents(from: jsonl)
            if let csv = writeCSV(events: recoveredEvents, filePrefix: leftover.filePrefix) {
                written.append(csv)
            } else {
                AppLog.persistence.error("Recovery CSV write failed for \(leftover.filePrefix)")
            }
            deleteSessionFiles(id: leftover.sessionId)
        }
        return written
    }

    // MARK: - Private (call with stateLock held unless noted)

    private func discardLocked() {
        closeJSONLLocked()
        if let meta {
            deleteSessionFiles(id: meta.sessionId)
        }
        meta = nil
        events = []
    }

    private func writeCSV(events: [DetectionLogEvent], filePrefix: String) -> URL? {
        let url = documentsDirectory.appendingPathComponent("\(filePrefix).csv")
        let body = ([DetectionLogEvent.csvHeader] + events.map { $0.csvRow() })
            .joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            AppLog.persistence.error("CSV write failed for \(filePrefix): \(error.localizedDescription)")
            return nil
        }
    }

    private func loadEvents(from url: URL) -> [DetectionLogEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(DetectionLogEvent.self, from: data)
        }
    }

    private nonisolated func jsonlURL(for sessionId: String) -> URL {
        supportDirectory.appendingPathComponent("active-\(sessionId).jsonl")
    }

    private nonisolated func metaURL(for sessionId: String) -> URL {
        supportDirectory.appendingPathComponent("active-\(sessionId).json")
    }

    private func closeJSONLLocked() {
        do {
            try jsonlHandle?.synchronize()
            try jsonlHandle?.close()
        } catch {
            AppLog.persistence.error("JSONL close failed: \(error.localizedDescription)")
        }
        jsonlHandle = nil
    }

    private func deleteSessionFiles(id: String) {
        try? fileManager.removeItem(at: jsonlURL(for: id))
        try? fileManager.removeItem(at: metaURL(for: id))
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static var iso8601Fractional: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DetectionLogEvent.timestampFormatter.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601Fractional: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = DetectionLogEvent.timestampFormatter.date(from: raw) {
                return date
            }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date \(raw)"
            )
        }
    }
}
