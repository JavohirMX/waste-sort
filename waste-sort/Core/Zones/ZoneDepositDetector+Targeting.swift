import CoreGraphics
import Foundation

// MARK: - Deposit targeting (dwell, swept crossings, trajectory, open-lid intent)

extension ZoneDepositDetector {
    /// The bin a vanished object would be credited to, or nil if it can never be credited.
    func target(for object: ZoneTrackedObject, zones: [DropZone]) -> ZoneDepositTarget? {
        // Waste the model only ever saw inside an open bin stays bin contents, whatever it
        // does next.
        guard object.arrivedFromOutside else { return nil }

        if let zoneID = object.zoneID {
            // Lost inside a zone: the dwell rule decides, exactly as before.
            guard object.dwell >= requiredDwellFrames else { return nil }
            return ZoneDepositTarget(
                zoneID: zoneID,
                zoneName: object.zoneName,
                binID: object.zoneBinID,
                viaTrajectory: false
            )
        }
        // A swept crossing is observed motion over a bin mouth; the trajectory march is
        // inference from velocity. Direct evidence wins.
        if let crossed = object.crossedZone,
           object.lastSeenAt - object.crossedAt <= crossingFreshWindow {
            return crossed
        }
        return trajectoryTarget(for: object, zones: zones)
    }

    /// The bin to credit when kinematics name none: exactly one lid stands open and the
    /// item vanished within reach of it.
    ///
    /// Drawer bins make this the load-bearing rule in practice. The item is dropped
    /// downward behind the drawer's front edge, so the flight is occluded in the very
    /// frames where it would enter the zone — the model sees it held, then never again.
    /// You cannot put anything into a closed drawer, so a tracked item vanishing next to
    /// the one open bin is a deposit by elimination. Ambiguity is refused: two open lids
    /// name no bin at all.
    func intentTarget(for object: ZoneTrackedObject, zones: [DropZone]) -> ZoneDepositTarget? {
        guard object.arrivedFromOutside,
              object.zoneID == nil,
              object.detectedFrames >= trajectoryMinFrames
        else { return nil }
        let open = zones.filter { binOpenState.isOpen(binID: $0.binID) }
        guard open.count == 1, let zone = open.first else { return nil }
        let dx = zone.centroid.x - object.last.center.x
        let dy = zone.centroid.y - object.last.center.y
        guard (dx * dx + dy * dy).squareRoot() <= intentMaxDistance else { return nil }
        // The lid must have been opened for this item — pulled while the item was in
        // sight, or shortly before it appeared. A lid that has been open for ages is
        // furniture, not a witness: that is how an item set down beside a bin stays
        // uncredited even when the lid happens to stand open.
        guard let openedAt = binOpenedAt[zone.binID],
              openedAt >= object.bornAt - intentOpenRecency
        else { return nil }
        return ZoneDepositTarget(zoneID: zone.id, zoneName: zone.name, binID: zone.binID, viaTrajectory: true)
    }

    /// Records the last zone an object's motion swept across between two tracked frames.
    /// Only meaningful movement counts: a segment long enough to have jumped a polygon
    /// that `contains` would have caught on one of its endpoints.
    func recordSweptCrossing(
        for object: ZoneTrackedObject,
        from previous: CGPoint,
        to current: CGPoint,
        zones: [DropZone],
        at timestamp: CFAbsoluteTime
    ) {
        let dx = current.x - previous.x
        let dy = current.y - previous.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.02 else { return }
        let steps = Int(length / 0.02)
        var hit: ZoneDepositTarget?
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let probe = CGPoint(x: previous.x + dx * t, y: previous.y + dy * t)
            if let zone = zones.first(where: { $0.contains(probe) }) {
                // Only an entry from outside counts. A segment that starts inside the zone
                // is that zone's exit — the dwell rule already judged the time spent in it,
                // and recording the way out would resurrect what the dwell rule refused.
                if hit == nil, !zone.contains(previous) {
                    hit = ZoneDepositTarget(zoneID: zone.id, zoneName: zone.name, binID: zone.binID, viaTrajectory: true)
                }
            }
        }
        if let hit {
            object.crossedZone = hit
            object.crossedAt = timestamp
        }
    }

    /// Where an object that vanished *outside* every zone was headed.
    ///
    /// The last box is marched forward along the direction of travel, and the first zone
    /// it reaches within the (speed-scaled) reach wins. The projection rides the tracked
    /// motion; only when that motion is silence — a held item whose release was never
    /// tracked — may a fresh launch peak speak for it, and never contrary to motion the
    /// model actually saw. This only ever runs for an object lost outside every zone —
    /// one lost inside a zone goes through the dwell rule instead — so the projection can
    /// never trivially credit a zone the item is already sitting in.
    private func trajectoryTarget(for object: ZoneTrackedObject, zones: [DropZone]) -> ZoneDepositTarget? {
        guard object.detectedFrames >= trajectoryMinFrames else { return nil }
        var direction = object.velocity
        var speed = (direction.x * direction.x + direction.y * direction.y).squareRoot()
        if speed < trajectoryMinSpeed {
            let peakAge = object.lastSeenAt - object.peakAt
            if peakAge >= 0, peakAge <= peakVelocityWindow {
                let peakSpeed = (object.peakVelocity.x * object.peakVelocity.x
                    + object.peakVelocity.y * object.peakVelocity.y).squareRoot()
                if peakSpeed > speed {
                    direction = object.peakVelocity
                    speed = peakSpeed
                }
            }
        }
        guard speed >= trajectoryMinSpeed else { return nil }
        let dx = direction.x / speed
        let dy = direction.y / speed
        let reach = min(
            trajectoryMaxReach,
            trajectoryReach + speed * trajectorySpeedReachGain
        )

        // Only bins the object was actually closing on. Without this a box already
        // overlapping a zone edge would be credited even as it is carried away from it.
        let center = object.last.center
        let approaching = zones.filter { zone in
            let toZone = CGPoint(x: zone.centroid.x - center.x, y: zone.centroid.y - center.y)
            return toZone.x * dx + toZone.y * dy > 0
        }
        guard !approaching.isEmpty else { return nil }

        let step: CGFloat = 0.01
        var travelled: CGFloat = 0
        while travelled <= reach {
            let probe = object.last.box.offsetBy(dx: dx * travelled, dy: dy * travelled)
            // The whole box, not just its center: an item whose leading edge is already over
            // the bin mouth has arrived, even though its center has not.
            let samples = [
                CGPoint(x: probe.midX, y: probe.midY),
                CGPoint(x: probe.minX, y: probe.minY),
                CGPoint(x: probe.maxX, y: probe.minY),
                CGPoint(x: probe.maxX, y: probe.maxY),
                CGPoint(x: probe.minX, y: probe.maxY)
            ]
            let hit = approaching.first { zone in samples.contains(where: zone.contains) }
            if let hit {
                return ZoneDepositTarget(
                    zoneID: hit.id,
                    zoneName: hit.name,
                    binID: hit.binID,
                    viaTrajectory: true
                )
            }
            travelled += step
        }
        return nil
    }
}
