import CoreGraphics
import Foundation

final class AprilTagBinStateDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingTags: [TrackedAprilTag] = []
    private var pendingTimestamp: CFAbsoluteTime = 0
    private var hasPendingTags: Bool = false
    private var lastSeenTimestamps: [UUID: CFAbsoluteTime] = [:]

    init() {}

    func ingest(tags: [TrackedAprilTag], timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        lock.lock()
        defer { lock.unlock() }
        pendingTags = tags
        pendingTimestamp = timestamp
        hasPendingTags = true
    }

    func update(
        zones: [DropZone],
        tagBindings: [UUID: Int] = [:], // Zone ID -> Tag ID
        config: AprilTagConfig = .standard,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> AprilTagStatusFrame {
        lock.lock()
        defer { lock.unlock() }

        let tags = hasPendingTags ? pendingTags : []
        let frameTimestamp = hasPendingTags ? pendingTimestamp : timestamp
        pendingTags.removeAll(keepingCapacity: true)
        hasPendingTags = false

        var tagsByID: [Int: TrackedAprilTag] = [:]
        for tag in tags { tagsByID[tag.id] = tag }

        var statuses: [UUID: BinOpenness] = [:]

        for (index, zone) in zones.enumerated() {
            let explicitTagID = tagBindings[zone.id]
            let targetTagID = explicitTagID ?? index
            var matchingTag = tagsByID[targetTagID]
            if matchingTag == nil && explicitTagID == nil {
                // Geometric containment fallback
                matchingTag = tags.first(where: { zone.contains($0.center) })
            }

            if let tag = matchingTag {
                lastSeenTimestamps[zone.id] = frameTimestamp
                statuses[zone.id] = BinOpenness(
                    state: .open,
                    confidence: 0.98,
                    tagID: tag.id,
                    lastSeenAt: frameTimestamp
                )
            } else {
                let lastSeen = lastSeenTimestamps[zone.id] ?? 0
                let elapsed = frameTimestamp - lastSeen
                if lastSeen > 0 && elapsed <= config.staleTimeout {
                    // Hold open status during brief frame dropouts
                    statuses[zone.id] = BinOpenness(
                        state: .open,
                        confidence: max(0.2, 1.0 - (elapsed / config.staleTimeout)),
                        tagID: targetTagID,
                        lastSeenAt: lastSeen
                    )
                } else {
                    // Stale timeout elapsed -> Bin is CLOSED
                    statuses[zone.id] = BinOpenness(
                        state: .closed,
                        confidence: 0.98,
                        tagID: targetTagID,
                        lastSeenAt: lastSeen
                    )
                }
            }
        }

        return AprilTagStatusFrame(statuses: statuses, detectedTags: tags, timestamp: frameTimestamp)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastSeenTimestamps.removeAll()
        pendingTags.removeAll()
        hasPendingTags = false
    }
}
