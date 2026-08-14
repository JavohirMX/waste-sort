import CoreGraphics
import Foundation

/// Presence helpers for the top category bar lighting.
enum CategoryPresence {
    static func isDetected(binID: String, counts: [String: Int]) -> Bool {
        (counts[binID] ?? 0) > 0
    }
}

/// Picks the largest tracked box as primary, with area hysteresis to avoid flicker.
enum PrimaryTrackSelector {
    /// Returns the preferred primary track given current tracks and optional previous primary.
    static func select(
        from tracks: [TrackedDetection],
        previousID: Int?,
        hysteresis: CGFloat = Theme.primaryAreaHysteresis
    ) -> TrackedDetection? {
        guard !tracks.isEmpty else { return nil }

        let ranked = tracks.sorted { area($0) > area($1) }
        guard let largest = ranked.first else { return nil }

        guard let previousID,
              let previous = tracks.first(where: { $0.id == previousID })
        else {
            return largest
        }

        let previousArea = area(previous)
        let largestArea = area(largest)
        if previous.id == largest.id {
            return previous
        }
        if largestArea >= previousArea * hysteresis {
            return largest
        }
        return previous
    }

    static func area(_ track: TrackedDetection) -> CGFloat {
        max(0, track.displayXywhn.width) * max(0, track.displayXywhn.height)
    }
}
