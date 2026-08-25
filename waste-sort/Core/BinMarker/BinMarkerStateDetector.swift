import CoreGraphics
import Foundation

/// Turns confirmed strip sightings into per-zone openness.
///
/// The rule is the one the physical setup implies and nothing more: the strip is mounted where
/// a shut bin hides it, so seeing it means open. What the state machine adds is patience —
/// a bin does not close the instant a strip drops out of one frame, because most dropouts are
/// an arm, not a lid.
///
/// Detection runs on its own queue and the frame arrives here a pass later, so staleness is
/// measured against the caller's clock rather than the frame's. Charging that latency against
/// the timeout is what keeps a short timeout honest.
nonisolated final class BinMarkerStateDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [BinMarkerDetection] = []
    private var pendingTimestamp: CFAbsoluteTime = 0
    private var hasPending = false
    private var lastSeen: [UUID: CFAbsoluteTime] = [:]
    private var lastSlot: [UUID: Int] = [:]
    private var lastDegraded: [UUID: Bool] = [:]
    private var lastDetections: [BinMarkerDetection] = []

    init() {}

    /// Hands a finished scan over from the detection queue.
    func ingest(
        detections: [BinMarkerDetection],
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        lock.lock()
        defer { lock.unlock() }
        pending = detections
        pendingTimestamp = timestamp
        hasPending = true
    }

    /// - Parameter bindings: zone id → marker slot. A zone with no entry falls back to its
    ///   position in `zones`, which is what makes the feature work before anyone has opened
    ///   settings.
    func update(
        zones: [DropZone],
        bindings: [UUID: Int] = [:],
        style: BinMarkerStyle,
        config: BinMarkerStateConfig = .standard,
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> BinMarkerStatusFrame {
        lock.lock()
        defer { lock.unlock() }

        let detections: [BinMarkerDetection]
        let frameTimestamp: CFAbsoluteTime
        if hasPending {
            detections = pending
            frameTimestamp = pendingTimestamp
            lastDetections = detections
            pending.removeAll(keepingCapacity: true)
            hasPending = false
        } else {
            detections = []
            frameTimestamp = timestamp
        }
        let now = max(frameTimestamp, timestamp)

        var bySlot: [Int: BinMarkerDetection] = [:]
        for detection in detections {
            guard let slot = detection.slot(style: style) else { continue }
            // Prefer a fully read strip over a degraded one when both name the same bin.
            if let existing = bySlot[slot.index], !existing.isDegraded { continue }
            bySlot[slot.index] = detection
        }

        let activeZoneIDs = Set(zones.map(\.id))
        lastSeen = lastSeen.filter { activeZoneIDs.contains($0.key) }
        lastSlot = lastSlot.filter { activeZoneIDs.contains($0.key) }
        lastDegraded = lastDegraded.filter { activeZoneIDs.contains($0.key) }

        var statuses: [UUID: BinMarkerOpenness] = [:]
        for (index, zone) in zones.enumerated() {
            let slot = bindings[zone.id] ?? index
            if let detection = bySlot[slot] {
                lastSeen[zone.id] = frameTimestamp
                lastSlot[zone.id] = slot
                lastDegraded[zone.id] = detection.isDegraded
                statuses[zone.id] = BinMarkerOpenness(
                    state: .open,
                    // A degraded strip is a real sighting, just a less specific one; the
                    // confidence says so rather than the state pretending otherwise.
                    confidence: detection.isDegraded ? 0.82 : 0.97,
                    slot: slot,
                    isDegraded: detection.isDegraded,
                    isCoasting: false,
                    lastSeenAt: frameTimestamp
                )
                continue
            }

            let seen = lastSeen[zone.id] ?? 0
            let elapsed = now - seen
            if seen > 0, elapsed <= config.staleTimeout {
                statuses[zone.id] = BinMarkerOpenness(
                    state: .open,
                    confidence: min(0.95, max(0.2, 1 - elapsed / config.staleTimeout)),
                    slot: lastSlot[zone.id] ?? slot,
                    isDegraded: lastDegraded[zone.id] ?? false,
                    isCoasting: true,
                    lastSeenAt: seen
                )
            } else {
                statuses[zone.id] = BinMarkerOpenness(
                    state: .closed,
                    confidence: 0.95,
                    slot: lastSlot[zone.id] ?? slot,
                    isDegraded: false,
                    isCoasting: false,
                    lastSeenAt: seen
                )
            }
        }

        return BinMarkerStatusFrame(
            statuses: statuses,
            detections: detections.isEmpty ? lastDetections : detections,
            timestamp: frameTimestamp
        )
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        lastDetections.removeAll()
        lastSeen.removeAll()
        lastSlot.removeAll()
        lastDegraded.removeAll()
        hasPending = false
        pendingTimestamp = 0
    }
}
