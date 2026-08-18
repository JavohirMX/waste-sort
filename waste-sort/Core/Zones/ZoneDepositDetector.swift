import CoreGraphics
import Foundation

/// An item that was released inside a zone — the "thrown away" event.
nonisolated struct ZoneDeposit: Identifiable, Equatable, Sendable {
    let trackID: Int
    let classKey: String
    let className: String
    let conf: Float
    /// Last box seen inside the zone, normalized image space.
    let boxXywhn: CGRect
    let zoneID: UUID
    let zoneName: String
    let zoneBinID: String
    let dwellFrames: Int

    var id: Int { trackID }

    /// True when the detected category matches the bin the zone stands for.
    var isCorrect: Bool { BinGuide.info(for: classKey).id == zoneBinID }
}

/// What one frame of zone evaluation produced.
nonisolated struct ZoneFrameResult: Equatable, Sendable {
    /// Items released this frame.
    var deposits: [ZoneDeposit] = []
    /// Zones with an item inside them right now — drives the dashed live outline.
    var occupiedZoneIDs: Set<UUID> = []
    /// Subset of `occupiedZoneIDs` whose item has met the dwell requirement and
    /// would be counted if the tracker lost it on this frame.
    var armedZoneIDs: Set<UUID> = []
}

/// Arms a track once it has *entered* a zone from outside and dwelt there, then fires
/// when the tracker drops it.
///
/// Three things have to be true for a deposit, and each rules out a different false positive:
/// the track was first seen outside every zone (something the model only notices once it is
/// already in the bin was never thrown in on camera), it then stayed inside one zone for
/// `requiredDwellFrames` (a hand passing over the wrong bin does not count), and it vanished
/// there rather than being carried back out.
nonisolated final class ZoneDepositDetector {
    /// Consecutive frames a track must stay inside one zone before it can fire.
    var requiredDwellFrames: Int = 3

    private struct Armed {
        var zoneID: UUID
        var zoneName: String
        var zoneBinID: String
        var dwell: Int
        var classKey: String
        var className: String
        var conf: Float
        var boxXywhn: CGRect
    }

    private var armed: [Int: Armed] = [:]
    /// Track IDs observed outside every zone at least once — only these can be armed.
    private var enteredFromOutside: Set<Int> = []

    func reset() {
        armed.removeAll(keepingCapacity: true)
        enteredFromOutside.removeAll(keepingCapacity: true)
    }

    func update(tracks: [TrackedDetection], zones: [DropZone]) -> ZoneFrameResult {
        guard !zones.isEmpty else {
            armed.removeAll(keepingCapacity: true)
            enteredFromOutside.removeAll(keepingCapacity: true)
            return ZoneFrameResult()
        }

        var live = Set<Int>()
        live.reserveCapacity(tracks.count)
        var occupied = Set<UUID>()

        for track in tracks {
            live.insert(track.id)
            let center = CGPoint(x: track.displayXywhn.midX, y: track.displayXywhn.midY)
            guard let zone = zones.first(where: { $0.contains(center) }) else {
                // Outside every zone: disarm, and mark the track as eligible to enter.
                armed[track.id] = nil
                enteredFromOutside.insert(track.id)
                continue
            }

            // Occupancy is about what the operator can see, so it counts every item
            // sitting in the zone — including ones that can never be credited.
            occupied.insert(zone.id)

            // Materialised straight into a zone — we never saw it cross the boundary,
            // so it was not thrown in on camera.
            guard enteredFromOutside.contains(track.id) else { continue }

            let previous = armed[track.id]?.zoneID == zone.id ? armed[track.id] : nil
            // A coasting box is the tracker holding the last known position, not the
            // model still seeing the object. Counting those frames would let an item
            // reach the dwell threshold purely by vanishing, which is the opposite of
            // what the threshold is for.
            let dwell = (previous?.dwell ?? 0) + (track.isCoasting ? 0 : 1)
            armed[track.id] = Armed(
                zoneID: zone.id,
                zoneName: zone.name,
                zoneBinID: zone.binID,
                dwell: dwell,
                classKey: track.classKey,
                className: track.className,
                conf: track.conf,
                boxXywhn: track.displayXywhn
            )
        }

        enteredFromOutside.formIntersection(live)

        var deposits: [ZoneDeposit] = []
        for (trackID, state) in armed where !live.contains(trackID) {
            armed[trackID] = nil
            guard state.dwell >= requiredDwellFrames else { continue }
            deposits.append(
                ZoneDeposit(
                    trackID: trackID,
                    classKey: state.classKey,
                    className: state.className,
                    conf: state.conf,
                    boxXywhn: state.boxXywhn,
                    zoneID: state.zoneID,
                    zoneName: state.zoneName,
                    zoneBinID: state.zoneBinID,
                    dwellFrames: state.dwell
                )
            )
        }

        var armedZoneIDs = Set<UUID>()
        for state in armed.values where state.dwell >= requiredDwellFrames {
            armedZoneIDs.insert(state.zoneID)
        }

        return ZoneFrameResult(
            deposits: deposits.sorted { $0.trackID < $1.trackID },
            occupiedZoneIDs: occupied,
            armedZoneIDs: armedZoneIDs
        )
    }
}
