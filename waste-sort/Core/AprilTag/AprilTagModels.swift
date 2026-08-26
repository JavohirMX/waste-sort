import CoreGraphics
import Foundation

// `BinOpennessState` moved to `Core/Zones/BinOpennessState.swift` when a second detector
// started producing it. It is shared vocabulary now, not an AprilTag detail.

/// Status for a single zone.
struct BinOpenness: Equatable, Sendable {
    var state: BinOpennessState = .unknown
    var confidence: Double = 0.0
    var tagID: Int?
    var matchedTagIDs: [Int] = []
    var boundTagIDs: [Int] = []
    var lastSeenAt: CFAbsoluteTime = 0.0

    init(
        state: BinOpennessState = .unknown,
        confidence: Double = 0.0,
        tagID: Int? = nil,
        matchedTagIDs: [Int] = [],
        boundTagIDs: [Int] = [],
        lastSeenAt: CFAbsoluteTime = 0.0
    ) {
        self.state = state
        self.confidence = confidence
        self.tagID = tagID ?? matchedTagIDs.first
        self.matchedTagIDs = matchedTagIDs.isEmpty ? (tagID.map { [$0] } ?? []) : matchedTagIDs
        self.boundTagIDs = boundTagIDs
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
    /// Diagnostics from the most recent detection pass, for the debug overlay. Nil when
    /// AprilTag detection is off.
    var detectorStats: AprilTagFrameStats?
    /// Non-nil when the tag detector itself failed to initialize; lid gating is inert.
    /// Surfaced in the live HUD because empty detections would otherwise look like
    /// "no tags in view" forever.
    var detectorFailureReason: String?

    nonisolated var closedZoneIDs: Set<UUID> {
        Set(statuses.compactMap { zoneID, status in
            status.state == .closed ? zoneID : nil
        })
    }

    nonisolated var openZoneIDs: Set<UUID> {
        Set(statuses.compactMap { zoneID, status in
            status.state == .open ? zoneID : nil
        })
    }

    init(
        statuses: [UUID: BinOpenness] = [:],
        detectedTags: [TrackedAprilTag] = [],
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        detectorStats: AprilTagFrameStats? = nil,
        detectorFailureReason: String? = nil
    ) {
        self.statuses = statuses
        self.detectedTags = detectedTags
        self.timestamp = timestamp
        self.detectorStats = detectorStats
        self.detectorFailureReason = detectorFailureReason
    }
}

/// Configuration settings for AprilTag detection and state machine.
struct AprilTagConfig: Codable, Equatable, Sendable {
    var tagFamilyName: String = "tag16h5" // Long distance / fast shutter
    var staleTimeout: CFAbsoluteTime = 2.0 // Missing > timeout -> Closed
    var sampleInterval: CFAbsoluteTime = 0.0 // 0.0 = every single camera frame

    static let staleTimeoutRange = 0.10...5.0
    static let staleTimeoutStep = 0.10
    static let tagsPerBinGroup = 3

    static func defaultTagIDs(forIndex index: Int) -> [Int] {
        let start = index * tagsPerBinGroup
        return (start..<(start + tagsPerBinGroup)).map { $0 }
    }

    init(
        tagFamilyName: String = "tag16h5",
        staleTimeout: CFAbsoluteTime = 2.0,
        sampleInterval: CFAbsoluteTime = 0.0
    ) {
        self.tagFamilyName = tagFamilyName
        self.staleTimeout = staleTimeout
        self.sampleInterval = sampleInterval
    }

    static let standard = AprilTagConfig()
}
