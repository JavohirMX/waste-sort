import CoreGraphics
import Foundation

/// One frame's evidence about a physical item, in image-normalized space.
nonisolated struct Sighting {
    var center: CGPoint
    var box: CGRect
    var classKey: String
    var className: String
    var conf: Float
    /// Set once the on-device model has named this item.
    var confirmedBinID: String?
}

/// The bin an object would be credited to if it never comes back.
nonisolated struct ZoneDepositTarget {
    let zoneID: UUID
    let zoneName: String
    let binID: String
    let viaTrajectory: Bool
}

/// The detector's memory of one physical item, stitched across tracker ids and
/// relabels. Owns the belief math, the kinematics a vanish is judged against,
/// and the credit state that survives a disappearance.
nonisolated final class ZoneTrackedObject {
    let id = UUID()
    var trackID: Int
    /// When the object was first resolved — the window the open-lid witness rule
    /// judges lid transitions against.
    let bornAt: CFAbsoluteTime
    var trackSegments = 1
    /// Fused class belief across the object's whole life. Recency decay is long
    /// (deposit preset) so a flicker to the wrong label cannot outvote a steady
    /// reading, while a genuinely different item later in life still can.
    let belief = BeliefEngine(config: .deposit)
    /// Lifetime window-vote math for the legacy pipeline. Idle under `.belief`.
    var legacy = LegacyDecisionEngine()
    /// A Foundation-model confirmation, once one has been attached to this object.
    ///
    /// Not a vote. The verdicts below sum confidence over every frame, so an item seen for
    /// a second before the model answers has already banked far more weight for the
    /// detector's guess than the confirmation could ever outvote — and the model is
    /// asked precisely because that guess is the thing in doubt. A confirmation
    /// therefore replaces the verdict outright, whichever pipeline is active.
    var confirmed: (key: String, name: String, conf: Float)?
    /// Distinct classes the model reported, for the `classesSeen` diagnostics.
    private(set) var classesSeen = 0
    private var seenClasses: Set<String> = []
    /// Evidence the object is not simply waste already lying in a bin: it was seen
    /// outside every zone at some point, or it was first seen inside a *closed* one.
    var arrivedFromOutside = false
    var zoneID: UUID?
    var zoneName = ""
    var zoneBinID = ""
    var dwell = 0
    /// When the object entered its current zone. Nil when it is outside every zone.
    var zoneEnteredAt: CFAbsoluteTime?
    /// A vanish-preview cue has already been sent for this disappearance.
    var didEmitThrowFeedback = false
    /// An in-zone "Not here!" cue is currently live.
    var didEmitInZoneIncorrect = false
    /// The wrong bin the in-zone cue was for — used to ignore short blinks and edge jitter.
    var lastWrongZoneBinID: String?
    /// When the object first left `lastWrongZoneBinID`. Nil while it is still there
    /// (including a vanish whose pending target is that same bin).
    var leftWrongZoneAt: CFAbsoluteTime?
    /// Frames the model actually saw this object, across every id it wore.
    var detectedFrames = 0
    var last: Sighting
    var lastSeenAt: CFAbsoluteTime
    /// Smoothed motion in normalized widths per second — the direction a vanish is
    /// judged against.
    var velocity: CGPoint = .zero
    /// Strongest instantaneous motion observed, and when. The smoothed velocity lags a
    /// release by design; for an item whose flight is never tracked (motion blur), the
    /// last few launch frames are the only kinematic trace a throw leaves.
    var peakVelocity: CGPoint = .zero
    var peakAt: CFAbsoluteTime = 0
    /// The zone the object's motion last swept across between two tracked frames —
    /// evidence a fast item passed over a bin mouth even though no frame saw its
    /// center inside.
    var crossedZone: ZoneDepositTarget?
    var crossedAt: CFAbsoluteTime = 0
    /// Last sighting that was inside a zone, which is what an ordinary deposit reports.
    var lastInZone: Sighting?
    var missingSince: CFAbsoluteTime?
    /// Resolved once, on the frame the object vanishes. Nil means it can never be
    /// credited, so it is neither settling now nor a deposit later.
    var pendingTarget: ZoneDepositTarget?
    /// Whether the target bin has been seen open at any point since the object vanished.
    var sawBinOpen = false

    init(trackID: Int, sighting: Sighting, at time: CFAbsoluteTime) {
        self.trackID = trackID
        self.bornAt = time
        self.last = sighting
        self.lastSeenAt = time
    }

    func note(
        _ sighting: Sighting,
        at time: CFAbsoluteTime,
        smoothing: CGFloat,
        pipeline: DecisionPipeline
    ) {
        if pipeline == .legacy {
            legacy.observe(
                classKey: sighting.classKey,
                className: sighting.className,
                conf: sighting.conf,
                at: time
            )
            return
        }
        if detectedFrames > 0 {
            let dt = CGFloat(max(time - lastSeenAt, 1e-3))
            let instant = CGPoint(
                x: (sighting.center.x - last.center.x) / dt,
                y: (sighting.center.y - last.center.y) / dt
            )
            velocity = CGPoint(
                x: smoothing * instant.x + (1 - smoothing) * velocity.x,
                y: smoothing * instant.y + (1 - smoothing) * velocity.y
            )
            if instant.x * instant.x + instant.y * instant.y >
                peakVelocity.x * peakVelocity.x + peakVelocity.y * peakVelocity.y {
                peakVelocity = instant
                peakAt = time
            }
        }
        detectedFrames += 1
        lastSeenAt = time
        last = sighting
        if sighting.confirmedBinID != nil {
            confirmed = (sighting.classKey, sighting.className, sighting.conf)
        }
        if seenClasses.insert(sighting.classKey).inserted {
            classesSeen += 1
        }
        if pipeline == .legacy {
            legacy.observe(
                classKey: sighting.classKey,
                className: sighting.className,
                conf: sighting.conf,
                at: time
            )
            return
        }
        belief.observe(
            classKey: sighting.classKey,
            className: sighting.className,
            conf: sighting.conf,
            at: time
        )
    }

    /// The object's bin verdict, frozen once when it vanishes so decay does not
    /// keep running during the reacquisition window.
    ///
    /// A Foundation-model confirmation replaces the verdict outright. Decisive
    /// beliefs report the winning class; anything else falls back to the safe
    /// stream rather than parroting a coin flip as a confident answer.
    func resolvedVerdict(at time: CFAbsoluteTime, pipeline: DecisionPipeline) -> DepositVerdict {
        if let confirmed {
            return DepositVerdict(
                classKey: confirmed.key,
                className: confirmed.name,
                conf: confirmed.conf,
                modelTopClassKey: confirmed.key,
                wasUncertain: false,
                margin: 1
            )
        }
        if pipeline == .legacy {
            // Main's verdict: lifetime confidence argmax, always confident.
            let verdict = legacy.verdict()
            return DepositVerdict(
                classKey: verdict.classKey,
                className: verdict.className,
                conf: max(verdict.weight, 0.001),
                modelTopClassKey: verdict.classKey,
                wasUncertain: false,
                margin: 1
            )
        }
        let state = belief.currentState(at: time)
        guard state.isDecided, !state.topKey.isEmpty else {
            let fallback = BinGuide.bin(id: BinGuide.fallbackBinID)
            return DepositVerdict(
                classKey: fallback.id,
                className: fallback.title,
                conf: Float(state.probabilities[state.topKey] ?? 0),
                modelTopClassKey: state.topKey,
                wasUncertain: true,
                margin: Float(state.margin)
            )
        }
        return DepositVerdict(
            classKey: state.topKey,
            className: state.classNameByKey[state.topKey] ?? state.topKey,
            conf: Float(state.probabilities[state.topKey] ?? 0),
            modelTopClassKey: state.topKey,
            wasUncertain: false,
            margin: Float(state.margin)
        )
    }

    /// Live category attribution for HUD cues (not scoring): the confirmation when
    /// present, otherwise the active pipeline's current leader with no fallback.
    func verdictClass(at time: CFAbsoluteTime, pipeline: DecisionPipeline) -> (key: String, name: String, conf: Float) {
        if let confirmed { return confirmed }
        if pipeline == .legacy {
            let verdict = legacy.verdict()
            return (verdict.classKey, verdict.className, max(verdict.weight, 0.001))
        }
        let state = belief.currentState(at: time)
        guard !state.topKey.isEmpty else {
            return (BinGuide.unknown.id, BinGuide.unknown.title, 0)
        }
        return (
            state.topKey,
            state.classNameByKey[state.topKey] ?? state.topKey,
            Float(state.probabilities[state.topKey] ?? 0)
        )
    }
}
