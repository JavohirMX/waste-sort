import CoreGraphics
import Foundation

/// Something the detector can credit to a bin.
///
/// Both kinds of sighting answer the same two questions — where it was, and how much of it was
/// showing — and once identity comes from position, nothing else about them matters here.
nonisolated protocol BinMarkerSighting {
    var center: CGPoint { get }
    /// How much of the marker was visible, for choosing between two that land on one bin.
    var reach: Int { get }
}

extension BinMarkerDashRow: BinMarkerSighting {
    var reach: Int { dashes }
}

extension BinMarkerDetection: BinMarkerSighting {
    /// A fully read rhythm beats one named by ink alone whatever their sizes; past that, more
    /// scan lines is more strip.
    var reach: Int { (isDegraded ? 0 : 1 << 20) + lineCount }
}

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

    /// Takes no style. It used to need one to know how a sighting named its bin; nothing here
    /// asks that question any more. Whether something is one of our prints at all is settled
    /// upstream, in the scanner and the confirmation gate — by the time a sighting arrives
    /// here, the only question left is which bin it is nearest to.
    func update(
        zones: [DropZone],
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

        let rowsByZone = bind(rows, to: zones, config: config)
        let stripsByZone = bind(detections, to: zones, config: config)

        let activeZoneIDs = Set(zones.map(\.id))
        lastSeen = lastSeen.filter { activeZoneIDs.contains($0.key) }
        lastSlot = lastSlot.filter { activeZoneIDs.contains($0.key) }
        lastDegraded = lastDegraded.filter { activeZoneIDs.contains($0.key) }

        var statuses: [UUID: BinMarkerOpenness] = [:]
        for (index, zone) in zones.enumerated() {
            if let row = rowsByZone[zone.id] {
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
            if let detection = stripsByZone[zone.id] {
                lastSeen[zone.id] = frameTimestamp
                lastSlot[zone.id] = index
                lastDegraded[zone.id] = detection.isDegraded
                statuses[zone.id] = BinMarkerOpenness(
                    state: .open,
                    // A degraded strip is a real sighting, just a less specific one; the
                    // confidence says so rather than the state pretending otherwise.
                    confidence: detection.isDegraded ? 0.82 : 0.97,
                    slot: index,
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
                    slot: lastSlot[zone.id] ?? index,
                    isDegraded: lastDegraded[zone.id] ?? false,
                    isCoasting: true,
                    lastSeenAt: seen
                )
            } else {
                statuses[zone.id] = BinMarkerOpenness(
                    state: .closed,
                    confidence: 0.95,
                    slot: lastSlot[zone.id] ?? index,
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

    /// Assigns each sighting to the bin it belongs to, by where it is.
    ///
    /// This is the entire identity mechanism, for every style, and it is worth being blunt
    /// about why it can be this thin: the camera is bolted overhead and the bins do not move,
    /// so a marker's position in the frame already says which drawer produced it. Encoding
    /// that into the marker as well — as an ink, as a bar rhythm — was answering a question
    /// this installation does not ask, and every failure the feature has had came from the
    /// encoding rather than from the finding. A colour cone wide enough to survive the room's
    /// light was wide enough to match the room's rubbish; bar widths are the first thing
    /// distance takes.
    ///
    /// So all three bins carry the *same* printed marker. Nothing has to be bound in settings,
    /// nothing can be stuck on the wrong drawer, and a strip that goes missing is replaced
    /// from whichever spare is nearest to hand.
    ///
    /// Nearest centre wins, within a radius, and one sighting per zone: two landing on the
    /// same bin means the one showing more of itself is the marker and the other is something
    /// else.
    private func bind<Sighting: BinMarkerSighting>(
        _ sightings: [Sighting],
        to zones: [DropZone],
        config: BinMarkerStateConfig
    ) -> [UUID: Sighting] {
        var byZone: [UUID: Sighting] = [:]
        for sighting in sightings {
            var bestZone: UUID?
            var bestDistance = config.maxBindingDistance
            for zone in zones {
                let centre = zone.centroid
                let dx = centre.x - sighting.center.x
                let dy = centre.y - sighting.center.y
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < bestDistance {
                    bestDistance = distance
                    bestZone = zone.id
                }
            }
            guard let bestZone else { continue }
            if let existing = byZone[bestZone], existing.reach >= sighting.reach { continue }
            byZone[bestZone] = sighting
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
