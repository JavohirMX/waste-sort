import CoreGraphics
import Foundation

// MARK: - Reaping, scoring, and object resolution

extension ZoneDepositDetector {
    /// Everything one reaping pass produced.
    struct ReapResult {
        var deposits: [ZoneDeposit] = []
        var drops: [DepositDrop] = []
        var armedZoneIDs: Set<UUID> = []
        var settlingZoneIDs: Set<UUID> = []
    }

    /// Scores everything whose reacquisition window ran out, drops it, and computes the
    /// per-zone armed/settling sets the HUD reacts to.
    func reapAndArm(at timestamp: CFAbsoluteTime) -> ReapResult {
        var result = ReapResult()
        let settled = objects.filter { object in
            guard let missingSince = object.missingSince else { return false }
            return timestamp - missingSince >= reacquireGrace
        }
        for object in settled {
            let credited = deposit(from: object)
            if credited.isEmpty, let drop = dropRecord(for: object) {
                result.drops.append(drop)
            }
            result.deposits.append(contentsOf: credited)
        }
        if !settled.isEmpty {
            let dead = Set(settled.map(ObjectIdentifier.init))
            objects.removeAll { dead.contains(ObjectIdentifier($0)) }
            byTrackID = byTrackID.filter { !dead.contains(ObjectIdentifier($0.value)) }
        }

        for object in objects {
            if let target = object.pendingTarget {
                result.settlingZoneIDs.insert(target.zoneID)
                continue
            }
            guard object.missingSince == nil,
                  object.arrivedFromOutside,
                  let zoneID = object.zoneID,
                  object.dwell >= requiredDwellFrames
            else { continue }
            result.armedZoneIDs.insert(zoneID)
        }
        result.deposits.sort { $0.trackID < $1.trackID }
        result.drops.sort { $0.trackID < $1.trackID }
        return result
    }

    /// Names why a settled object earned nothing. Mirrors `deposit(from:)`'s
    /// guard so the chip on Live always states the true gate.
    private func dropRecord(for object: ZoneTrackedObject) -> DepositDrop? {
        guard let missingSince = object.missingSince else { return nil }
        if let target = object.pendingTarget {
            guard !object.sawBinOpen else { return nil }
            return DepositDrop(
                reason: .binReadShut,
                trackID: object.trackID,
                targetBinID: target.binID,
                timestamp: missingSince
            )
        }
        return DepositDrop(
            reason: .outsideZones,
            trackID: object.trackID,
            targetBinID: object.zoneBinID.isEmpty ? nil : object.zoneBinID,
            timestamp: missingSince
        )
    }

    private func deposit(from object: ZoneTrackedObject) -> [ZoneDeposit] {
        // Nothing goes into a closed bin.
        guard let target = object.pendingTarget, object.sawBinOpen else { return [] }

        let verdict = object.resolvedVerdict(at: object.missingSince ?? object.lastSeenAt, pipeline: pipeline)
        let box = target.viaTrajectory
            ? object.last.box
            : (object.lastInZone?.box ?? object.last.box)
        return [
            ZoneDeposit(
                id: object.id,
                trackID: object.trackID,
                classKey: verdict.classKey,
                className: verdict.className,
                conf: verdict.conf,
                modelTopClassKey: verdict.modelTopClassKey,
                wasUncertain: verdict.wasUncertain,
                margin: verdict.margin,
                boxXywhn: box,
                zoneID: target.zoneID,
                zoneName: target.zoneName,
                zoneBinID: target.binID,
                dwellFrames: target.viaTrajectory ? 0 : object.dwell,
                trackSegments: object.trackSegments,
                classesSeen: object.classesSeen,
                viaTrajectory: target.viaTrajectory,
                binWasOpen: object.sawBinOpen
            )
        ]
    }

    /// Resolves a live track to the object it belongs to, stitching across a dropout when
    /// the geometry says it is the same thing.
    func resolveObject(
        for track: TrackedDetection,
        sighting: Sighting,
        now: CFAbsoluteTime,
        claimed: Set<ObjectIdentifier>
    ) -> ZoneTrackedObject {
        if let known = byTrackID[track.id] {
            return known
        }

        var best: ZoneTrackedObject?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for candidate in objects {
            // Two objects visible at once are two objects, however similar they look — so
            // anything already claimed this frame is off limits. `missingSince` is nil for
            // an object the model lost only moments ago, on this very frame, which is
            // exactly the case a relabel produces when the tracker confirms the new id
            // immediately: elapsed is zero, and it is still the same thing.
            guard !claimed.contains(ObjectIdentifier(candidate)) else { continue }
            let elapsed = candidate.missingSince.map { now - $0 } ?? 0
            guard elapsed <= reacquireGrace else { continue }
            // Deliberately class-blind. The model relabelling a cup mid-carry is one of the
            // things this layer exists to absorb.
            let limit = min(
                reacquireMaxRadius,
                reacquireRadius + reacquireDriftPerSecond * CGFloat(max(0, elapsed))
            )
            let dx = candidate.last.center.x - sighting.center.x
            let dy = candidate.last.center.y - sighting.center.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= limit, distance < bestDistance else { continue }
            bestDistance = distance
            best = candidate
        }

        if let best {
            byTrackID[best.trackID] = nil
            best.trackID = track.id
            best.trackSegments += 1
            byTrackID[track.id] = best
            return best
        }

        let created = ZoneTrackedObject(trackID: track.id, sighting: sighting, at: now)
        objects.append(created)
        byTrackID[track.id] = created
        return created
    }
}
