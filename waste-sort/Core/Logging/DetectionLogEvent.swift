import Foundation

struct DetectionLogEvent: Codable, Equatable, Sendable {
    var timestamp: Date
    var sessionId: String
    var sessionStartedAt: Date
    var trackId: Int
    var classKey: String
    var className: String
    var bin: String
    var confidence: Double
    var model: String
    var confidenceThreshold: Double
    var iouThreshold: Double
    var cameraId: String
    var boxX: Double
    var boxY: Double
    var boxW: Double
    var boxH: Double
    var fps: Int
    /// `first_seen` when a track is confirmed, `zone_deposit` when it is released in a zone.
    /// Optional so pre-upgrade JSONL still decodes during crash recovery.
    var eventType: String?
    var zoneId: String?
    var zoneName: String?
    var zoneBin: String?
    var isCorrect: Bool?
    var dwellFrames: Int?
    /// True when the item was credited by where it was heading rather than by dwelling
    /// inside the zone. `dwellFrames` is 0 for these.
    var viaTrajectory: Bool?
    var rawClassKey: String?
    /// True when the verdict was resolved by fallback instead of a decisive belief read.
    var beliefUncertain: Bool?
    /// Belief lead of the top class over the runner-up (0…1).
    var beliefMargin: Double?
    /// The model's own leader on deposit events, even when the advised bin overruled it.
    var modelTopClassKey: String?

    static let eventTypeFirstSeen = "first_seen"
    static let eventTypeZoneDeposit = "zone_deposit"
    static let eventTypeClassSwitch = "class_switch"
    static let eventTypeCoastStart = "coast_start"

    static let csvHeader = [
        "timestamp", "sessionId", "sessionStartedAt", "trackId",
        "classKey", "className", "bin", "confidence",
        "model", "confidenceThreshold", "iouThreshold", "cameraId",
        "boxX", "boxY", "boxW", "boxH", "fps", "eventType",
        "zoneId", "zoneName", "zoneBin", "isCorrect", "dwellFrames",
        "viaTrajectory", "rawClassKey", "beliefUncertain", "beliefMargin", "modelTopClassKey"
    ].joined(separator: ",")

    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func csvRow() -> String {
        [
            Self.timestampFormatter.string(from: timestamp),
            escape(sessionId),
            Self.timestampFormatter.string(from: sessionStartedAt),
            String(trackId),
            escape(classKey),
            escape(className),
            escape(bin),
            String(format: "%.4f", confidence),
            escape(model),
            String(format: "%.2f", confidenceThreshold),
            String(format: "%.2f", iouThreshold),
            escape(cameraId),
            String(format: "%.4f", boxX),
            String(format: "%.4f", boxY),
            String(format: "%.4f", boxW),
            String(format: "%.4f", boxH),
            String(fps),
            escape(eventType ?? ""),
            escape(zoneId ?? ""),
            escape(zoneName ?? ""),
            escape(zoneBin ?? ""),
            isCorrect.map { $0 ? "true" : "false" } ?? "",
            dwellFrames.map(String.init) ?? "",
            viaTrajectory.map { $0 ? "true" : "false" } ?? "",
            escape(rawClassKey ?? ""),
            beliefUncertain.map { $0 ? "true" : "false" } ?? "",
            beliefMargin.map { String(format: "%.4f", $0) } ?? "",
            escape(modelTopClassKey ?? "")
        ].joined(separator: ",")
    }

    private func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct DetectionSessionMeta: Codable, Equatable, Sendable {
    var sessionId: String
    var sessionStartedAt: Date
    var filePrefix: String
}
