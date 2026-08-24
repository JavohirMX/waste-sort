import Foundation

/// Presence helpers for the top category bar lighting.
enum CategoryPresence {
    static func isDetected(binID: String, counts: [String: Int]) -> Bool {
        (counts[binID] ?? 0) > 0
    }

    /// Live HUD counts: dirty recyclable increments residual and recyclable together.
    static func counts(from tracks: [TrackedDetection]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for track in tracks where !track.isCoasting {
            for binID in BinGuide.barBinIDs(for: track.classKey) {
                counts[binID, default: 0] += 1
            }
        }
        return counts
    }
}
