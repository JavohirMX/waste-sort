import Foundation

/// Presence helpers for the top category bar lighting.
enum CategoryPresence {
    static func isDetected(binID: String, counts: [String: Int]) -> Bool {
        (counts[binID] ?? 0) > 0
    }
}
