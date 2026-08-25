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
    private var pendingRows: [BinMarkerDashRow] = []
    private var pendingTimestamp: CFAbsoluteTime = 0
    private var hasPending = false
    private var lastSeen: [UUID: CFAbsoluteTime] = [:]
    private var lastSlot: [UUID: Int] = [:]
    private var lastDegraded: [UUID: Bool] = [:]
    private var lastDetections: [BinMarkerDetection] = []
    private var lastRows: [BinMarkerDashRow] = []

    init() {}

    /// Hands a finished scan over from the detection queue.
    func ingest(
        detections: [BinMarkerDetection],
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        lock.lock()
        defer { lock.unlock() }
        pending = detections
        pendingRows = []
        pendingTimestamp = timestamp
        hasPending = true
    }

    /// Hands over a finished dash scan instead. Same state machine either way — coasting,
    /// timeout and pruning do not care how a bin was recognised.
    func ingest(
        rows: [BinMarkerDashRow],
        timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) {
        lock.lock()
        defer { lock.unlock() }
        pending = []
        pendingRows = rows
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
        let rows: [BinMarkerDashRow]
        let frameTimestamp: CFAbsoluteTime
        if hasPending {
            detections = pending
            rows = pendingRows
            frameTimestamp = pendingTimestamp
            lastDetections = detections
            lastRows = rows
            pending.removeAll(keepingCapacity: true)
            pendingRows.removeAll(keepingCapacity: true)
            hasPending = false
        } else {
            detections = []
            rows = []
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
        let byZone = style.usesDashRows ? bind(rows: rows, to: zones, config: config) : [:]

        let activeZoneIDs = Set(zones.map(\.id))
        lastSeen = lastSeen.filter { activeZoneIDs.contains($0.key) }
        lastSlot = lastSlot.filter { activeZoneIDs.contains($0.key) }
        lastDegraded = lastDegraded.filter { activeZoneIDs.contains($0.key) }

        var statuses: [UUID: BinMarkerOpenness] = [:]
        for (index, zone) in zones.enumerated() {
            let slot = bindings[zone.id] ?? index
            if let row = byZone[zone.id] {
                lastSeen[zone.id] = frameTimestamp
                lastSlot[zone.id] = index
                lastDegraded[zone.id] = false
                statuses[zone.id] = BinMarkerOpenness(
                    state: .open,
                    // More dashes is more of the row clear of the counter edge. Five is the
                    // floor the scanner will report at all, so the scale starts there.
                    confidence: min(0.98, 0.80 + 0.02 * Double(row.dashes - 4)),
                    slot: index,
                    isDegraded: false,
                    isCoasting: false,
                    lastSeenAt: frameTimestamp
                )
                continue
            }
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
            rows: rows.isEmpty ? lastRows : rows,
            timestamp: frameTimestamp
        )
    }

    /// Assigns each dash row to the bin it belongs to, by where it is.
    ///
    /// This is the entire identity mechanism of the dash style, and it is worth being blunt
    /// about why it can be this thin: the camera is bolted overhead and the bins do not move,
    /// so a row's position in the frame already says which drawer produced it. Encoding that
    /// into the marker — as colour, as a bar rhythm — was solving a problem this installation
    /// does not have, and every failure so far came from the encoding rather than from the
    /// finding.
    ///
    /// Nearest centre wins, within a radius, and one row per zone: two rows landing on the
    /// same bin means the longer one is the marker and the other is something else.
    private func bind(
        rows: [BinMarkerDashRow],
        to zones: [DropZone],
        config: BinMarkerStateConfig
    ) -> [UUID: BinMarkerDashRow] {
        var byZone: [UUID: BinMarkerDashRow] = [:]
        for row in rows {
            var bestZone: UUID?
            var bestDistance = config.maxBindingDistance
            for zone in zones {
                let centre = zone.centroid
                let dx = centre.x - row.center.x
                let dy = centre.y - row.center.y
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < bestDistance {
                    bestDistance = distance
                    bestZone = zone.id
                }
            }
            guard let bestZone else { continue }
            if let existing = byZone[bestZone], existing.dashes >= row.dashes { continue }
            byZone[bestZone] = row
        }
        return byZone
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
