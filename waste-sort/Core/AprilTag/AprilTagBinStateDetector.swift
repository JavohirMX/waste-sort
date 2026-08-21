import CoreGraphics
import Foundation

final class AprilTagBinStateDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingTags: [TrackedAprilTag] = []
    private var pendingTimestamp: CFAbsoluteTime = 0
    private var hasPendingTags: Bool = false
    private var lastSeenTimestamps: [UUID: CFAbsoluteTime] = [:]
    private var lastSeenTagIDs: [UUID: Int] = [:]
    private var lastActiveTags: [TrackedAprilTag] = []

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
        tagBindings: [UUID: [Int]] = [:], // Zone ID -> Tag IDs
        config: AprilTagConfig = .standard,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> AprilTagStatusFrame {
        lock.lock()
        defer { lock.unlock() }

        let tags: [TrackedAprilTag]
        let frameTimestamp: CFAbsoluteTime

        if hasPendingTags {
            tags = pendingTags
            frameTimestamp = pendingTimestamp
            lastActiveTags = tags
            pendingTags.removeAll(keepingCapacity: true)
            hasPendingTags = false
        } else {
            tags = []
            frameTimestamp = timestamp
        }

        // Staleness is measured against the caller's clock, not the frame's. Detection runs
        // on its own queue now, so an ingested frame can be a pass older than "now"; charging
        // that latency against the stale timeout is what keeps a short timeout honest.
        let now = max(frameTimestamp, timestamp)

        var tagsByID: [Int: TrackedAprilTag] = [:]
        for tag in tags { tagsByID[tag.id] = tag }

        var statuses: [UUID: BinOpenness] = [:]
        let activeZoneIDs = Set(zones.map(\.id))

        // Prune stale zones no longer active
        lastSeenTimestamps = lastSeenTimestamps.filter { activeZoneIDs.contains($0.key) }
        lastSeenTagIDs = lastSeenTagIDs.filter { activeZoneIDs.contains($0.key) }

        for (index, zone) in zones.enumerated() {
            let explicitTagIDs = tagBindings[zone.id]
            let targetTagIDs = explicitTagIDs ?? AprilTagConfig.defaultTagIDs(forIndex: index)
            let matchedTags = targetTagIDs.compactMap { tagsByID[$0] }

            var activeMatchingTags = matchedTags
            if activeMatchingTags.isEmpty && explicitTagIDs == nil {
                // Geometric containment fallback
                activeMatchingTags = tags.filter { zone.contains($0.center) }
            }

            if !activeMatchingTags.isEmpty {
                lastSeenTimestamps[zone.id] = frameTimestamp
                let primaryTagID = activeMatchingTags.first?.id
                if let id = primaryTagID {
                    lastSeenTagIDs[zone.id] = id
                }
                let ratio = Double(activeMatchingTags.count) / Double(max(1, targetTagIDs.count))
                let confidence = min(0.98, 0.90 + (0.08 * ratio))
                statuses[zone.id] = BinOpenness(
                    state: .open,
                    confidence: confidence,
                    tagID: primaryTagID,
                    matchedTagIDs: activeMatchingTags.map(\.id),
                    boundTagIDs: targetTagIDs,
                    lastSeenAt: frameTimestamp
                )
            } else {
                let lastSeen = lastSeenTimestamps[zone.id] ?? 0
                let elapsed = now - lastSeen
                let rememberedTagID = lastSeenTagIDs[zone.id] ?? targetTagIDs.first

                if lastSeen > 0 && elapsed <= config.staleTimeout {
                    // Hold open status during brief frame dropouts
                    let decayConfidence = min(0.98, max(0.2, 1.0 - (max(0, elapsed) / config.staleTimeout)))
                    statuses[zone.id] = BinOpenness(
                        state: .open,
                        confidence: decayConfidence,
                        tagID: rememberedTagID,
                        matchedTagIDs: [],
                        boundTagIDs: targetTagIDs,
                        lastSeenAt: lastSeen
                    )
                } else {
                    // Stale timeout elapsed -> Bin is CLOSED
                    statuses[zone.id] = BinOpenness(
                        state: .closed,
                        confidence: 0.98,
                        tagID: rememberedTagID,
                        matchedTagIDs: [],
                        boundTagIDs: targetTagIDs,
                        lastSeenAt: lastSeen
                    )
                }
            }
        }

        let returnedTags = !tags.isEmpty ? tags : lastActiveTags
        return AprilTagStatusFrame(statuses: statuses, detectedTags: returnedTags, timestamp: frameTimestamp)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastSeenTimestamps.removeAll()
        lastSeenTagIDs.removeAll()
        pendingTags.removeAll()
        lastActiveTags.removeAll()
        hasPendingTags = false
        pendingTimestamp = 0
    }
}
