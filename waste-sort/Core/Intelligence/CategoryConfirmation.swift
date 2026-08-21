import CoreGraphics
import Foundation

/// What the model said about one item, before anyone decides whether to believe it.
nonisolated struct CategoryReading: Equatable, Sendable {
    /// A `BinGuide` id, or nil when the model answered "unclear".
    let binID: String?
    /// What the model called the item, in its own words. Log only.
    let label: String
    /// The model's own stated confidence. Self-reported by a language model, so useful for
    /// a threshold and for the log, not calibrated like a detector score.
    let confidence: Double
}

/// A category the on-device model committed to for one item, and that was accepted.
nonisolated struct ConfirmedCategory: Equatable, Sendable {
    /// A `BinGuide` id — `organic`, `residual`, or `clean_inorganic`.
    let binID: String
    let confidence: Double
    let label: String
}

/// What the confirmation layer is doing with one track, as the overlay needs to draw it.
///
/// The four cases exist to keep one promise legible on screen: **a plain box has not been
/// confirmed.** Only `.confirmed` draws the double border, and anything the layer still
/// intends to act on is visibly unsettled, so a box waiting its turn can never be mistaken
/// for one the model has already answered.
nonisolated enum TrackConfirmation: Equatable, Sendable {
    /// The layer has nothing to say about this track — switched off, or it has been asked
    /// as often as it is going to be. Drawn exactly as it was before the layer existed.
    case idle
    /// Eligible and queued, but the model is busy with something else.
    case pending
    /// Being looked at right now: either choosing a frame to send, or with the model.
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

/// Reads one cropped item image.
///
/// Reports what the model said and nothing more — whether an answer is good enough to lock
/// is `CategoryConfirmationCoordinator`'s call, so that policy lives in one place and the
/// rejected answers are still there to be logged.
///
/// The live implementation talks to the on-device Foundation model; tests substitute their
/// own so the queueing and locking rules can be exercised without a model.
nonisolated protocol CategoryConfirming: Sendable {
    func read(image: CGImage) async throws -> CategoryReading
}
