import CoreGraphics
import Foundation

/// Binary bin openness state.
enum BinOpennessState: String, Codable, Sendable {
    case open
    case closed
    case unknown

    var acceptsItems: Bool { self == .open }

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .unknown: return "Unknown"
        }
    }
}

/// Status for a single zone.
struct BinOpenness: Equatable, Sendable {
    var state: BinOpennessState = .unknown
    var confidence: Double = 0.0
    var tagID: Int?
    var lastSeenAt: CFAbsoluteTime = 0.0

    init(
        state: BinOpennessState = .unknown,
        confidence: Double = 0.0,
        tagID: Int? = nil,
        lastSeenAt: CFAbsoluteTime = 0.0
    ) {
        self.state = state
        self.confidence = confidence
        self.tagID = tagID
        self.lastSeenAt = lastSeenAt
    }
}

/// Normalized AprilTag detection in 0...1 space.
struct TrackedAprilTag: Equatable, Sendable, Identifiable {
    var id: Int
    var center: CGPoint
    var corners: [CGPoint] // 4 corners in normalized coordinates
    var hamming: Int
    var decisionMargin: Float
    var timestamp: CFAbsoluteTime

    init(
        id: Int,
        center: CGPoint,
        corners: [CGPoint],
        hamming: Int,
        decisionMargin: Float,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        self.id = id
        self.center = center
        self.corners = corners
        self.hamming = hamming
        self.decisionMargin = decisionMargin
        self.timestamp = timestamp
    }
}

/// Frame status snapshot emitted every detection tick.
struct AprilTagStatusFrame: Equatable, Sendable {
    var statuses: [UUID: BinOpenness] = [:]
    var detectedTags: [TrackedAprilTag] = []
    var timestamp: CFAbsoluteTime = 0.0

    var closedZoneIDs: Set<UUID> {
        Set(statuses.compactMap { zoneID, status in
            status.state == .closed ? zoneID : nil
        })
    }

    var openZoneIDs: Set<UUID> {
        Set(statuses.compactMap { zoneID, status in
            status.state == .open ? zoneID : nil
        })
    }

    init(
        statuses: [UUID: BinOpenness] = [:],
        detectedTags: [TrackedAprilTag] = [],
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        self.statuses = statuses
        self.detectedTags = detectedTags
        self.timestamp = timestamp
    }
}

/// Configuration settings for AprilTag detection and state machine.
struct AprilTagConfig: Codable, Equatable, Sendable {
    var tagFamilyName: String = "tag16h5" // Long distance / fast shutter
    var staleTimeout: CFAbsoluteTime = 0.30 // Missing > 0.30s -> Closed
    var sampleInterval: CFAbsoluteTime = 0.0 // 0.0 = every single camera frame

    init(
        tagFamilyName: String = "tag16h5",
        staleTimeout: CFAbsoluteTime = 0.30,
        sampleInterval: CFAbsoluteTime = 0.0
    ) {
        self.tagFamilyName = tagFamilyName
        self.staleTimeout = staleTimeout
        self.sampleInterval = sampleInterval
    }

    static let standard = AprilTagConfig()
}
