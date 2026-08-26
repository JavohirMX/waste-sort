import Foundation

/// Decides whether one tracked detection has matured into a Private Cloud
/// Compute verdict audit — the "judge every YOLO prediction" path.
///
/// Unlike the deposit trigger, this fires while the item is merely being
/// looked at: YOLO has said something for a few consecutive frames, and the
/// crop + that claim go to the judge whether or not the item is ever scored.
/// Pure and synchronous, so it runs on the inference queue at zero cost.
nonisolated enum PCCVerdictAuditPolicy {
    /// Consecutive tracked frames before an item's crop is worth judging. One
    /// or two boxes are often tracker noise; three is a thing the camera is
    /// actually being shown.
    static let maturityFrames = 3

    nonisolated enum Decision: Equatable, Sendable {
        case trigger
        case skip(SkipReason)
    }

    nonisolated enum SkipReason: Equatable, Sendable {
        /// PCC is switched off in settings — not an error, just quiet.
        case disabled
        /// This track has not been seen long enough to trust a crop from.
        case immature
        /// The judge already took this item (deposit path or an earlier audit).
        case alreadyRequested
    }

    /// - Parameters:
    ///   - framesSeen: consecutive frames this track id has existed for.
    ///   - pccEnabled: the judge feature is switched on in settings.
    ///   - alreadyRequested: `PCCArbiterService.hasRequested(trackId:)` or the
    ///     queue's dedupe already knows this track id.
    static func decision(
        framesSeen: Int,
        pccEnabled: Bool,
        alreadyRequested: Bool
    ) -> Decision {
        guard pccEnabled else { return .skip(.disabled) }
        guard alreadyRequested == false else { return .skip(.alreadyRequested) }
        guard framesSeen >= maturityFrames else { return .skip(.immature) }
        return .trigger
    }
}
