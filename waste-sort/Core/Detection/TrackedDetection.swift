import CoreGraphics
import Foundation

import CoreGraphics
import Foundation

/// Lightweight detection used as tracker input (normalized image coordinates).
struct RawDetection: Equatable, Sendable {
    let classKey: String
    let className: String
    let conf: Float
    /// Normalized rect (0…1) in image space, origin top-left.
    let xywhn: CGRect
    /// Soft color/texture evidence sampled inside the box, when appearance assist is on.
    var appearancePrior: AppearancePrior?
}

/// Confirmed track ready for overlay drawing and counting.
///
/// `nonisolated` because it is produced on the capture queue and read from several
/// off-main layers — the deposit detector and the confirmation coordinator both do — before
/// it ever reaches a view.
nonisolated struct TrackedDetection: Identifiable, Equatable, Sendable {
    let id: Int
    let classKey: String
    let className: String
    /// Last confidence observed for the locked class (not the current YOLO challenger).
    let conf: Float
    /// Inflated display rect in normalized coordinates.
    let displayXywhn: CGRect
    /// Consecutive frames the model has failed to find this track. Zero means the box
    /// comes from a real detection this frame; anything higher means it is frozen in
    /// place, still drawn but no longer evidence that the object is there.
    var misses: Int = 0
    /// This frame's belief leader. Empty means the same as `classKey`.
    var rawClassKey: String = ""
    /// Belief probability of this frame's leader (0 when nothing was seen yet).
    var rawConf: Float = 0
    /// True while the belief engine would not back `classKey` with a verdict —
    /// the UI should present this as "not sure", not as a confident answer.
    var beliefUncertain: Bool = false
    /// Lead of the belief leader over the runner-up, 0…1. Small values flag coin flips.
    var beliefMargin: Float = 0
    /// Set once the on-device Foundation model has named this item, and never cleared while
    /// the item stays on screen. The tracker itself never sets this — the confirmation layer
    /// does, on the way out — and it deliberately leaves `rawClassKey` alone so the log can
    /// still show what the detector thought.
    var confirmedBinID: String? = nil

    var isCoasting: Bool { misses > 0 }

    var observedClassKey: String { rawClassKey.isEmpty ? classKey : rawClassKey }

    var isClassPending: Bool { !rawClassKey.isEmpty && rawClassKey != classKey }

    /// What counting and logging should attribute this item to: a locked confirmation when
    /// there is one, otherwise this frame's raw detection.
    var vote: (classKey: String, className: String, conf: Float) {
        guard confirmedBinID == nil else { return (classKey, className, conf) }
        return (
            observedClassKey,
            rawClassKey.isEmpty ? className : rawClassKey,
            rawConf > 0 ? rawConf : conf
        )
    }
}
