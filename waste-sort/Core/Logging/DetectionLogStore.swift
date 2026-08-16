import Foundation

/// Session-scoped detection log. Appends JSONL while recording, then writes a Documents CSV on finish.
final class DetectionLogStore {
    static let shared = DetectionLogStore()

    let documentsDirectory: URL
    private let supportDirectory: URL
    private let fileManager: FileManager

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

    var isSessionActive: Bool { meta != nil }

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
        discardSessionFiles()
        let meta = DetectionSessionMeta(
            sessionId: id,
            sessionStartedAt: startedAt,
            filePrefix: filePrefix
        )
        self.meta = meta
        events = []

        if let data = try? encoder.encode(meta) {
            try? data.write(to: metaURL(for: id), options: .atomic)
        }

        let jsonl = jsonlURL(for: id)
        fileManager.createFile(atPath: jsonl.path, contents: nil)
        jsonlHandle = try? FileHandle(forWritingTo: jsonl)
        _ = try? jsonlHandle?.seekToEnd()
    }

    func append(_ event: DetectionLogEvent) {
        guard meta != nil else { return }
        events.append(event)
        guard let data = try? encoder.encode(event),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        if let payload = line.data(using: .utf8) {
            try? jsonlHandle?.write(contentsOf: payload)
            try? jsonlHandle?.synchronize()
        }
    }

    /// Writes Documents CSV (header-only when no events) and clears the active session.
    @discardableResult
    func finishSession() -> URL? {
        guard let meta else { return nil }
        closeJSONL()
        let url = writeCSV(events: events, filePrefix: meta.filePrefix)
        deleteSessionFiles(id: meta.sessionId)
        self.meta = nil
        events = []
        return url
    }

    /// Drops an in-progress session without writing a CSV (failed recording start).
    func discardSession() {
        discardSessionFiles()
        meta = nil
        events = []
    }

    /// Turns leftover JSONL sessions into Documents CSVs (crash / force-quit recovery).
    @discardableResult
    func recoverLeftoverSessions() -> [URL] {
        guard meta == nil else { return [] }

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
                try? fileManager.removeItem(at: metaFile)
                continue
            }
            let jsonl = jsonlURL(for: leftover.sessionId)
            let recoveredEvents = loadEvents(from: jsonl)
            if let csv = writeCSV(events: recoveredEvents, filePrefix: leftover.filePrefix) {
                written.append(csv)
            }
            deleteSessionFiles(id: leftover.sessionId)
        }
        return written
    }

    private func writeCSV(events: [DetectionLogEvent], filePrefix: String) -> URL? {
        let url = documentsDirectory.appendingPathComponent("\(filePrefix).csv")
        let body = ([DetectionLogEvent.csvHeader] + events.map { $0.csvRow() })
            .joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
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

    private func jsonlURL(for sessionId: String) -> URL {
        supportDirectory.appendingPathComponent("active-\(sessionId).jsonl")
    }

    private func metaURL(for sessionId: String) -> URL {
        supportDirectory.appendingPathComponent("active-\(sessionId).json")
    }

    private func closeJSONL() {
        try? jsonlHandle?.synchronize()
        try? jsonlHandle?.close()
        jsonlHandle = nil
    }

    private func discardSessionFiles() {
        closeJSONL()
        if let meta {
            deleteSessionFiles(id: meta.sessionId)
        }
    }

    private func deleteSessionFiles(id: String) {
        try? fileManager.removeItem(at: jsonlURL(for: id))
        try? fileManager.removeItem(at: metaURL(for: id))
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static var iso8601Fractional: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DetectionLogEvent.timestampFormatter.string(from: date))
        }
    }
}

private extension JSONDecoder.DateDecodingStrategy {
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
