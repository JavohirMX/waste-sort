import CoreGraphics
import Foundation

/// A category the on-device model committed to for one item.
nonisolated struct ConfirmedCategory: Equatable, Sendable {
    /// A `BinGuide` id — `organic`, `residual`, or `clean_inorganic`.
    let binID: String
    /// The model's own stated confidence. Self-reported by a language model, so useful for
    /// ordering and for the log, not calibrated like a detector score.
    let confidence: Double
    /// What the model called the item, in its own words. Log only.
    let label: String
}

/// What the confirmation layer is doing with one track, as the overlay needs to draw it.
nonisolated enum TrackConfirmation: Equatable, Sendable {
    /// Nothing in flight: either not eligible yet, or the model has been asked as often as
    /// it is going to be.
    case idle
    /// A request for this track is with the model right now.
    case thinking
    /// A verdict is locked in and will not change while the item stays on screen.
    case confirmed
}

/// Per-frame confirmation state, keyed by tracker id.
nonisolated struct ConfirmationFrame: Equatable, Sendable {
    var states: [Int: TrackConfirmation] = [:]

    func state(for trackID: Int) -> TrackConfirmation { states[trackID] ?? .idle }

    /// True when at least one request is with the model, for the HUD indicator.
    var isBusy: Bool { states.values.contains(.thinking) }

    var confirmedCount: Int { states.values.filter { $0 == .confirmed }.count }
}

/// Classifies one cropped item image.
///
/// The live implementation talks to the on-device Foundation model; tests substitute their
/// own so the queueing and locking rules can be exercised without a model.
nonisolated protocol CategoryConfirming: Sendable {
    /// - Returns: the category, or nil when the model looked and could not say. A nil is a
    ///   real answer — it just is not one worth locking.
    func confirm(image: CGImage) async throws -> ConfirmedCategory?
}
