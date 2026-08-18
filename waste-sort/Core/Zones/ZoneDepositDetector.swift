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

/// Arms a track once it has dwelt inside a zone, then fires when the tracker drops it.
///
/// Entering alone is not a deposit — an item carried over the wrong bin must not count.
/// Leaving the zone alive disarms; disappearing while armed is what we call "deposited".
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

    func reset() {
        armed.removeAll(keepingCapacity: true)
    }

    func update(tracks: [TrackedDetection], zones: [DropZone]) -> [ZoneDeposit] {
        guard !zones.isEmpty else {
            armed.removeAll(keepingCapacity: true)
            return []
        }

        var live = Set<Int>()
        live.reserveCapacity(tracks.count)

        for track in tracks {
            live.insert(track.id)
            let center = CGPoint(x: track.displayXywhn.midX, y: track.displayXywhn.midY)
            guard let zone = zones.first(where: { $0.contains(center) }) else {
                // Left every zone while still visible — not a deposit.
                armed[track.id] = nil
                continue
            }

            let dwell = armed[track.id]?.zoneID == zone.id ? (armed[track.id]?.dwell ?? 0) + 1 : 1
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
        return deposits.sorted { $0.trackID < $1.trackID }
    }
}
