import CoreGraphics
import Foundation

/// An item that was released into a bin — the "thrown away" event.
nonisolated struct ZoneDeposit: Identifiable, Equatable, Sendable {
    /// Stable across the blinks and class flips the object survived.
    let id: UUID
    /// Tracker id the object carried when it was last seen, for cross-referencing the raw log.
    let trackID: Int
    /// The bin verdict the system advised. When belief was decisive this is the model's
    /// top class; when it was not, this is `BinGuide.fallbackBinID` — residual, the
    /// regulation-safe stream.
    let classKey: String
    let className: String
    /// Belief probability behind `classKey` (0…1). For fallback verdicts this is how
    /// much evidence existed at all — deliberately unimpressive.
    let conf: Float
    /// The model's own leader regardless of decisiveness, for diagnostics and CSV
    /// post-analysis of where the engine had to overrule it.
    let modelTopClassKey: String
    /// True when the verdict was resolved by fallback rather than a confident read.
    let wasUncertain: Bool
    /// Lead of the top class over the runner-up (0…1). Small values flag coin flips.
    let margin: Float
    /// Last box the object was seen in, normalized image space — inside the zone for an
    /// ordinary deposit, just short of it for a trajectory one.
    let boxXywhn: CGRect
    let zoneID: UUID
    let zoneName: String
    let zoneBinID: String
    let dwellFrames: Int
    /// How many tracker ids this object went through — anything above 1 means the model
    /// lost it and it was stitched back together.
    let trackSegments: Int
    /// Distinct classes the model reported over the object's life. Above 1 means the
    /// category below is a vote, not a single confident answer.
    let classesSeen: Int
    /// True when the object was never seen strictly inside the zone: it vanished on its way
    /// in and was credited by where it was heading. `dwellFrames` is 0 for these.
    let viaTrajectory: Bool
    /// True when the target bin was open during the settling window. Credited deposits
    /// always have this true, because a closed lid is not counted.
    let binWasOpen: Bool

    /// True when the detected category matches the bin the item went into.
    /// Dirty recyclable is correct in residual or recyclable.
    var isCorrect: Bool {
        BinGuide.isAcceptedDeposit(classKey: classKey, zoneBinID: zoneBinID)
    }
}

/// Early HUD cue: a throw preview or an item held in the wrong zone. Not a scored deposit.
nonisolated struct ThrowFeedbackCue: Equatable, Sendable {
    let objectID: UUID
    let zoneBinID: String
    let isCorrect: Bool
    /// In-zone incorrect stays up until cancel; throw previews use the 1.8s auto-dismiss.
    let persistWhilePresent: Bool
}

/// Why an item that vanished never became a deposit. Surfaced on Live so a
/// kiosk that swallows throws explains itself instead of staying silent.
nonisolated enum DepositDropReason: Equatable, Sendable {
    /// Vanished with no zone under or along its path — nothing to credit.
    case outsideZones
    /// Had a target zone, but no open reading during the settling window:
    /// thrown at a bin whose lid (strip/tag) read shut.
    case binReadShut
}

/// One vanished item that did not become a deposit. Emitted on the frame it
/// was reaped; Live shows the latest one as a diagnostic chip.
nonisolated struct DepositDrop: Equatable, Sendable {
    let reason: DepositDropReason
    let trackID: Int
    /// The bin that would have been credited, when there was one.
    let targetBinID: String?
    let timestamp: CFAbsoluteTime
}

/// What one frame of zone evaluation produced.
nonisolated struct ZoneFrameResult: Equatable, Sendable {
    /// Items confirmed released this frame. Confirmation lags the disappearance by the
    /// reacquisition window, because that is the point.
    var deposits: [ZoneDeposit] = []
    /// Zones with an item inside them right now — drives the dashed live outline.
    var occupiedZoneIDs: Set<UUID> = []
    /// Subset of `occupiedZoneIDs` whose item has met the dwell requirement and would be
    /// counted if it stayed gone.
    var armedZoneIDs: Set<UUID> = []
    /// Zones holding an object that has vanished and is inside its reacquisition window —
    /// about to be counted unless the model finds it again.
    var settlingZoneIDs: Set<UUID> = []
    /// First-time throw / wrong-zone feedback this frame.
    var throwFeedbackCues: [ThrowFeedbackCue] = []
    /// Objects whose preview should come down (left the wrong zone, or came back).
    var cancelledThrowFeedbackIDs: Set<UUID> = []
    /// Vanished items that did NOT credit this frame, with why. Usually empty;
    /// non-empty means a throw happened and was not counted.
    var drops: [DepositDrop] = []
}

/// The frozen bin verdict for an object at the moment it vanishes.
nonisolated struct DepositVerdict: Equatable, Sendable {
    let classKey: String
    let className: String
    /// Belief probability behind `classKey`.
    let conf: Float
    /// The model's own leader even when `classKey` overruled it via fallback.
    let modelTopClassKey: String
    let wasUncertain: Bool
    let margin: Float
}
