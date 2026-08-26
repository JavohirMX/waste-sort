import CoreGraphics
import Foundation

/// Confirmation gate between "a strip appeared in one frame" and "that bin is open".
///
/// The scanner already throws away most of what could be mistaken for a marker: the rhythm has
/// to be one of three, the gaps have to agree with each other, and several scan lines have to
/// say the same thing. What it cannot rule out on its own is something strip-shaped moving
/// through the frame — a striped sleeve, a printed carton in someone's hands.
///
/// A strip on an open bin does not move. So the gate is simply that: a strip has to show up
/// twice, in the same place, before it counts. A degraded reading — ink without a rhythm —
/// needs one sighting more, because half its identity is missing.
///
/// Tracks are kept **by place, not by which strip it is**, because every bin now carries the
/// same printed marker and it is where the marker appears that names the bin. Keyed by strip,
/// three bins would share one track and confirming any one of them would confirm all three.
nonisolated final class BinMarkerTemporalFilter: @unchecked Sendable {
    /// Sightings in one place needed inside `windowSpan` before it is trusted.
    var requiredHits: Int = 2
    /// How far back corroborating sightings may be drawn from.
    var windowSpan: CFAbsoluteTime = 0.6
    /// How long a slot stays trusted after its last sighting. Longer than `windowSpan`, so a
    /// strip that flickers at range is not made to re-earn its place after every gap.
    var confirmationTTL: CFAbsoluteTime = 1.5
    /// Normalized centre drift allowed between corroborating sightings. An open bin holds
    /// still, so this only has to absorb the scanner's own jitter.
    var maxCenterDrift: CGFloat = 0.06

    private struct Track {
        var center: CGPoint
        var sightings: [CFAbsoluteTime] = []
        var confirmedUntil: CFAbsoluteTime = 0
    }

    private let lock = NSLock()
    private var tracks: [Track] = []

    init() {}

    /// The subset of `detections` that is trusted for this frame.
    func filter(
        _ detections: [BinMarkerDetection],
        style: BinMarkerStyle,
        timestamp: CFAbsoluteTime
    ) -> [BinMarkerDetection] {
        lock.lock()
        defer { lock.unlock() }

        expire(now: timestamp)

        var accepted: [BinMarkerDetection] = []
        accepted.reserveCapacity(detections.count)

        for detection in detections {
            // Still asked, but a narrower question than it used to be: not *which* bin this
            // strip belongs to — position answers that — only whether it is one of ours at
            // all. Under colour that means an ink and a rhythm that do not contradict each
            // other; under mono, a rhythm that reads.
            guard detection.slot(style: style) != nil else { continue }
            let index = track(near: detection.center)
            tracks[index].sightings.removeAll { timestamp - $0 > windowSpan }
            tracks[index].sightings.append(timestamp)
            // Follow the strip's own jitter rather than pinning the track to where it was
            // first seen, or a slow drift eventually walks out of its own tolerance.
            tracks[index].center = detection.center

            let needed = detection.isDegraded ? requiredHits + 1 : requiredHits
            if timestamp < tracks[index].confirmedUntil
                || tracks[index].sightings.count >= needed {
                tracks[index].confirmedUntil = timestamp + confirmationTTL
                accepted.append(detection)
            }
        }

        return accepted
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        tracks.removeAll()
    }

    /// The track this sighting continues, or a fresh one. Nearest wins, so two strips a hand's
    /// width apart never trade histories.
    private func track(near center: CGPoint) -> Int {
        var best: Int?
        var bestDistance = maxCenterDrift
        for (index, track) in tracks.enumerated() {
            let dx = track.center.x - center.x
            let dy = track.center.y - center.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= bestDistance {
                bestDistance = distance
                best = index
            }
        }
        if let best { return best }
        tracks.append(Track(center: center))
        return tracks.count - 1
    }

    private func expire(now: CFAbsoluteTime) {
        for index in tracks.indices {
            tracks[index].sightings.removeAll { now - $0 > windowSpan }
        }
        tracks.removeAll { $0.sightings.isEmpty && now >= $0.confirmedUntil }
    }
}
