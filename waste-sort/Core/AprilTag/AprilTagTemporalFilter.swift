import CoreGraphics
import Foundation

/// Confirmation gate that lets the detector run at a low decision margin without leaking
/// false positives into bin openness.
///
/// tag16h5 only carries 16 data bits, which is exactly why it stays readable at range - and
/// exactly why weak decodes land on random IDs. Those hits are scattered in both ID and image
/// position from frame to frame, while a real tag sits still on a bin lid. So instead of
/// raising the margin (which costs range) we require a weak ID to reappear near where it was
/// last seen before we trust it. Tags at or above `instantTrustMargin` bypass the gate, so a
/// close, crisp tag still registers on its first frame.
final class AprilTagTemporalFilter: @unchecked Sendable {
    /// Sightings of one ID needed inside `windowSpan` before that ID is trusted.
    var requiredHits: Int = 2
    /// How far back corroborating sightings may be drawn from.
    var windowSpan: CFAbsoluteTime = 0.60
    /// How long an ID stays trusted after its last sighting. Longer than `windowSpan` so a
    /// tag that flickers at range is not forced to re-confirm after every gap.
    var confirmationTTL: CFAbsoluteTime = 2.0
    /// Normalized centre drift allowed between corroborating sightings. Tags are static once
    /// a lid is open, so this only has to absorb detector jitter.
    var maxCenterDrift: CGFloat = 0.08

    /// Margin at or above which a tag skips confirmation entirely.
    var instantTrustMargin: Float = 50.0
    /// Margin at or above which `requiredHits` is enough; below it, one more hit is demanded.
    /// A weak-margin decode has roughly a 1-in-550 chance of landing on a valid tag16h5 code
    /// by accident, and a busy frame offers hundreds of candidate quads, so the weakest tier
    /// has to clear a higher bar.
    var strongMargin: Float = 30.0

    private struct Track {
        var sightings: [(timestamp: CFAbsoluteTime, center: CGPoint)] = []
        var confirmedUntil: CFAbsoluteTime = 0
    }

    private let lock = NSLock()
    private var tracks: [Int: Track] = [:]

    init() {}

    /// Returns the subset of `tags` that is trusted for this frame.
    func filter(_ tags: [TrackedAprilTag], timestamp: CFAbsoluteTime) -> [TrackedAprilTag] {
        lock.lock()
        defer { lock.unlock() }

        expireTracks(now: timestamp)

        var accepted: [TrackedAprilTag] = []
        accepted.reserveCapacity(tags.count)

        for tag in tags {
            var track = tracks[tag.id] ?? Track()
            track.sightings.removeAll { timestamp - $0.timestamp > windowSpan }
            track.sightings.append((timestamp: timestamp, center: tag.center))

            let alreadyTrusted = timestamp < track.confirmedUntil
            let needed = tag.decisionMargin >= strongMargin ? requiredHits : requiredHits + 1
            let trusted = alreadyTrusted
                || tag.decisionMargin >= instantTrustMargin
                || corroboratingHits(in: track, near: tag.center) >= needed

            if trusted {
                track.confirmedUntil = timestamp + confirmationTTL
                accepted.append(tag)
            }
            tracks[tag.id] = track
        }

        return accepted
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        tracks.removeAll()
    }

    private func corroboratingHits(in track: Track, near center: CGPoint) -> Int {
        track.sightings.reduce(into: 0) { count, sighting in
            let dx = sighting.center.x - center.x
            let dy = sighting.center.y - center.y
            if (dx * dx + dy * dy).squareRoot() <= maxCenterDrift { count += 1 }
        }
    }

    private func expireTracks(now: CFAbsoluteTime) {
        tracks = tracks.compactMapValues { track in
            var track = track
            track.sightings.removeAll { now - $0.timestamp > windowSpan }
            if track.sightings.isEmpty && now >= track.confirmedUntil { return nil }
            return track
        }
    }
}
