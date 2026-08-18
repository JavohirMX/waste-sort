import Combine
import Foundation

/// One confirmed deposit, as kept in the durable history.
nonisolated struct ZoneEventRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var classKey: String
    var className: String
    var zoneID: UUID
    var zoneName: String
    var zoneBinID: String
    var confidence: Double
    var isCorrect: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date,
        classKey: String,
        className: String,
        zoneID: UUID,
        zoneName: String,
        zoneBinID: String,
        confidence: Double,
        isCorrect: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.classKey = classKey
        self.className = className
        self.zoneID = zoneID
        self.zoneName = zoneName
        self.zoneBinID = zoneBinID
        self.confidence = confidence
        self.isCorrect = isCorrect
    }

    init(deposit: ZoneDeposit, timestamp: Date) {
        self.init(
            timestamp: timestamp,
            classKey: deposit.classKey,
            className: deposit.className,
            zoneID: deposit.zoneID,
            zoneName: deposit.zoneName,
            zoneBinID: deposit.zoneBinID,
            confidence: Double(deposit.conf),
            isCorrect: deposit.isCorrect
        )
    }

    var bin: BinInfo { BinGuide.info(for: classKey) }
    var zoneBin: BinInfo { BinGuide.info(for: zoneBinID) }

    static let csvHeader = "timestamp,classKey,className,zoneName,zoneBin,isCorrect,confidence"

    func csvRow() -> String {
        [
            timestamp.formatted(.iso8601.time(includingFractionalSeconds: true)),
            escape(classKey),
            escape(className),
            escape(zoneName),
            escape(zoneBinID),
            isCorrect ? "true" : "false",
            String(format: "%.4f", confidence),
        ].joined(separator: ",")
    }

    private func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// Always-on durable log of zone deposits, independent of video recording.
///
/// Append-only JSONL in Application Support so a crash never loses more than the
/// last line; loaded back into memory at launch to power the History tab.
@MainActor
final class ZoneEventHistoryStore: ObservableObject {
    static let shared = ZoneEventHistoryStore()

    /// Newest first.
    @Published private(set) var events: [ZoneEventRecord] = []

    private let fileManager: FileManager
    private let directory: URL
    private let exportDirectory: URL
    private var handle: FileHandle?
    private var lineCount = 0

    /// Kept in memory (and after compaction, on disk).
    private let memoryCap = 500
    private let compactThreshold = 5000
    private let compactTarget = 2000

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

    init(
        directory: URL? = nil,
        exportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("History", isDirectory: true)
        self.directory = root
        self.exportDirectory = exportDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: self.exportDirectory, withIntermediateDirectories: true)
        load()
    }

    var fileURL: URL { directory.appendingPathComponent("zone-events.jsonl") }

    func append(_ deposits: [ZoneDeposit], at timestamp: Date = Date()) {
        guard !deposits.isEmpty else { return }
        for deposit in deposits {
            append(ZoneEventRecord(deposit: deposit, timestamp: timestamp))
        }
    }

    func append(_ record: ZoneEventRecord) {
        write(record)
        events.insert(record, at: 0)
        if events.count > memoryCap {
            events.removeLast(events.count - memoryCap)
        }
        if lineCount > compactThreshold {
            compact()
        }
    }

    func clear() {
        closeHandle()
        try? fileManager.removeItem(at: fileURL)
        lineCount = 0
        events = []
    }

    /// Writes the whole in-memory history to a user-visible CSV and returns it.
    @discardableResult
    func exportCSV(now: Date = Date()) -> URL? {
        let url = exportDirectory
            .appendingPathComponent("\(SessionFileNamer.prefix(for: now))-history.csv")
        let rows = events.reversed().map { $0.csvRow() }
        let body = ([ZoneEventRecord.csvHeader] + rows).joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Disk

    private func load() {
        let lines = readLines()
        lineCount = lines.count
        let decoded = lines.compactMap { line -> ZoneEventRecord? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ZoneEventRecord.self, from: data)
        }
        events = Array(decoded.suffix(memoryCap).reversed())
    }

    private func readLines() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func write(_ record: ZoneEventRecord) {
        guard let data = try? encoder.encode(record),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        guard let payload = line.data(using: .utf8) else { return }
        if handle == nil {
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: payload)
        try? handle?.synchronize()
        lineCount += 1
    }

    /// Rewrites the file with only the newest `compactTarget` lines.
    private func compact() {
        let lines = readLines()
        guard lines.count > compactTarget else { return }
        closeHandle()
        let body = lines.suffix(compactTarget).joined(separator: "\n") + "\n"
        guard (try? body.write(to: fileURL, atomically: true, encoding: .utf8)) != nil else { return }
        lineCount = compactTarget
    }

    private func closeHandle() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}
