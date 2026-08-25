import CoreGraphics
import Foundation

/// Confirmation gate between "a strip appeared in one frame" and "that bin is open".
///
/// The scanner already throws away most of what could be mistaken for a marker: the rhythm has
/// to be one of three, the gaps have to agree with each other, and several scan lines have to
/// say the same thing. What it cannot rule out on its own is something strip-shaped moving
/// through the frame — a striped sleeve, a printed carton in someone's hands.
///
/// A strip on an open bin does not move. So the gate is simply that: a slot has to show up
/// twice, in the same place, before it counts. A degraded reading — ink without a rhythm —
/// needs one sighting more, because half its identity is missing.
nonisolated final class BinMarkerTemporalFilter: @unchecked Sendable {
    /// Sightings of one slot needed inside `windowSpan` before it is trusted.
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
        var sightings: [(timestamp: CFAbsoluteTime, center: CGPoint)] = []
        var confirmedUntil: CFAbsoluteTime = 0
    }

    private let lock = NSLock()
    private var tracks: [Int: Track] = [:]

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
            guard let slot = detection.slot(style: style) else { continue }
            var track = tracks[slot.index] ?? Track()
            track.sightings.removeAll { timestamp - $0.timestamp > windowSpan }
            track.sightings.append((timestamp: timestamp, center: detection.center))

            let needed = detection.isDegraded ? requiredHits + 1 : requiredHits
            let trusted = timestamp < track.confirmedUntil
                || corroborating(track, near: detection.center) >= needed
            if trusted {
                track.confirmedUntil = timestamp + confirmationTTL
                accepted.append(detection)
            }
            tracks[slot.index] = track
        }

        return accepted
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        tracks.removeAll()
    }

    private func corroborating(_ track: Track, near center: CGPoint) -> Int {
        track.sightings.reduce(into: 0) { count, sighting in
            let dx = sighting.center.x - center.x
            let dy = sighting.center.y - center.y
            if (dx * dx + dy * dy).squareRoot() <= maxCenterDrift { count += 1 }
        }
    }

    private func expire(now: CFAbsoluteTime) {
        tracks = tracks.compactMapValues { track in
            var track = track
            track.sightings.removeAll { now - $0.timestamp > windowSpan }
            if track.sightings.isEmpty, now >= track.confirmedUntil { return nil }
            return track
        }
    }
}
