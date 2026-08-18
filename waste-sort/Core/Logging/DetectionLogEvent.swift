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

    static let csvHeader =
        "timestamp,sessionId,sessionStartedAt,trackId,classKey,className,bin,confidence,model,confidenceThreshold,iouThreshold,cameraId,boxX,boxY,boxW,boxH,fps"

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
