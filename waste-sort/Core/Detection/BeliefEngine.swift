import Foundation

/// One object's fused class belief, recomputed per frame.
///
/// Probabilities are a recency-weighted normalization of every piece of evidence
/// injected for the object: each bucket decays exponentially with wall-clock time,
/// so recent frames outweigh stale ones and long-forgotten classes vanish entirely.
/// `isDecided` is the gate that turns this into a bin verdict: the top class must
/// clear an absolute bar *and* beat the runner-up by a margin *and* enough evidence
/// must exist at all. When it fails, callers are expected to treat the item as
/// uncertain rather than parroting a confident argmax.
nonisolated struct BeliefState: Equatable {
    /// Normalized belief per class key seen for this object (empty when no evidence yet).
    let probabilities: [String: Double]
    /// Last display name reported alongside each class key.
    let classNameByKey: [String: String]
    /// Highest-probability class. Ties break lexicographically so repeated runs agree.
    let topKey: String
    /// Second-highest class, or nil when only one class has any evidence.
    let runnerUpKey: String?
    /// `top` minus runner-up probability. 1.0 when only one class has evidence.
    let margin: Double
    /// True when the decision rule passes: threshold + margin + minimum evidence.
    let isDecided: Bool
    /// Total observations and injections ever recorded (not decayed) — the "how much
    /// have we actually seen" counter behind `minEvidenceEvents`.
    let evidenceEvents: Int
    /// Hysteresis-stable label. Nil until the first decided verdict locks it; afterwards
    /// it only moves when a challenger stays decisively ahead for `switchConfirmations`
    /// consecutive checks.
    let lockedClassKey: String?

    /// The label to show: the stable lock once one exists, otherwise the raw leader.
    var displayClassKey: String { lockedClassKey ?? topKey }
    /// True while the engine would not put a verdict behind `displayClassKey`.
    var isUncertain: Bool { lockedClassKey == nil || !isDecided }
}

/// Tunables for `BeliefEngine`. Two presets cover the app's two consumers: the live
/// overlay wants a short memory (labels follow the object now), the deposit verdict
/// wants a long one (the throw is judged once, on everything seen).
nonisolated struct BeliefConfig: Equatable, Sendable {
    /// Seconds for belief mass to halve. Evidence older than a few half-lives stops mattering.
    var halfLife: CFTimeInterval
    /// Probability the top class must reach before a verdict counts as decided.
    var decideThreshold: Double
    /// How far the top class must sit above the runner-up, guarding against two-class coin flips.
    var decideMargin: Double
    /// Consecutive decided checks a challenger must win before the stable label flips.
    var switchConfirmations: Int
    /// Evidence count below which the engine refuses to declare anything decided —
    /// one lucky frame should not produce a verdict.
    var minEvidenceEvents: Int

    /// Overlay-label policy: short memory so the badge tracks the item in hand.
    static let display = BeliefConfig(
        halfLife: WasteSortConfig.defaultBeliefDisplayHalfLife,
        decideThreshold: WasteSortConfig.defaultBeliefThreshold,
        decideMargin: WasteSortConfig.defaultBeliefMargin,
        switchConfirmations: WasteSortConfig.defaultBeliefSwitchConfirmations,
        minEvidenceEvents: WasteSortConfig.defaultBeliefMinEvidenceEvents
    )

    /// Deposit-verdict policy: near-lifetime memory — the throw is scored once, on
    /// everything seen across blinks, relabels and id stitches.
    static let deposit = BeliefConfig(
        halfLife: WasteSortConfig.defaultBeliefDepositHalfLife,
        decideThreshold: WasteSortConfig.defaultBeliefThreshold,
        decideMargin: WasteSortConfig.defaultBeliefMargin,
        switchConfirmations: WasteSortConfig.defaultBeliefSwitchConfirmations,
        minEvidenceEvents: WasteSortConfig.defaultBeliefMinEvidenceDepositEvents
    )
}

/// Fuses per-frame class confidences (plus optional external evidence such as
/// appearance priors or re-check passes) into one running belief per object.
///
/// Replaces both previous voters — the tracker's sliding-window confidence sum and
/// the deposit detector's lifetime sum — which disagreed with each other and had no
/// notion of uncertainty. The engine is deliberately generic over class keys: the
/// mapping from key to bin stays in `BinGuide`, keeping this unit-testable without
/// model or UI dependencies.
///
/// Threading: instances are owned by whichever pipeline stage creates them (tracker /
/// deposit detector live on the inference queue). Nothing here touches shared state.
///
/// Per-frame contract: call `currentState(at:)` exactly once per frame — it advances
/// the hysteresis streak as a side effect.
nonisolated final class BeliefEngine {
    var config: BeliefConfig

    private var weights: [String: Double] = [:]
    private var classNames: [String: String] = [:]
    private var evidenceEvents = 0
    private var lastTime: CFTimeInterval?
    private var lockedKey: String?
    private var challengerStreak = 0

    /// Weights below this are garbage collected so long sessions cannot grow unbounded.
    private static let weightFloor = 1e-6

    init(config: BeliefConfig) {
        self.config = config
    }

    func reset() {
        weights.removeAll(keepingCapacity: true)
        classNames.removeAll(keepingCapacity: true)
        evidenceEvents = 0
        lastTime = nil
        lockedKey = nil
        challengerStreak = 0
    }

    /// Records one model observation. `conf` is used directly as evidence weight.
    func observe(classKey: String, className: String, conf: Float, at time: CFTimeInterval) {
        inject(classKey: classKey, className: className, weight: Double(conf), at: time)
    }

    /// Records external evidence (appearance prior, zoom re-check). `weight` is
    /// pre-scaled by the caller — a strong re-check pass may inject more than its raw
    /// confidence, a soft color prior less.
    func inject(classKey: String, className: String, weight: Double, at time: CFTimeInterval) {
        applyDecay(to: time)
        guard weight > 0 else { return }
        weights[classKey, default: 0] += weight
        if !className.isEmpty {
            classNames[classKey] = className
        }
        evidenceEvents += 1
    }

    /// Recomputes probabilities at `time` and advances label hysteresis.
    ///
    /// Call once per frame from the queue that owns this engine.
    func currentState(at time: CFTimeInterval) -> BeliefState {
        applyDecay(to: time)

        let entries = weights.map { (key: $0.key, probability: normalized($0.value)) }
        let ranked = entries.sorted { lhs, rhs in
            if lhs.probability == rhs.probability {
                return lhs.key < rhs.key
            }
            return lhs.probability > rhs.probability
        }
        guard let top = ranked.first else {
            return BeliefState(
                probabilities: [:],
                classNameByKey: classNames,
                topKey: "",
                runnerUpKey: nil,
                margin: 0,
                isDecided: false,
                evidenceEvents: evidenceEvents,
                lockedClassKey: nil
            )
        }

        let runnerUp = ranked.count > 1 ? ranked[1].key : nil
        let margin = ranked.count > 1 ? top.probability - ranked[1].probability : 1
        let decided = evidenceEvents >= config.minEvidenceEvents
            && top.probability >= config.decideThreshold
            && margin >= config.decideMargin

        advanceLock(topKey: top.key, decided: decided)

        return BeliefState(
            probabilities: Dictionary(uniqueKeysWithValues: ranked.map { ($0.key, $0.probability) }),
            classNameByKey: classNames,
            topKey: top.key,
            runnerUpKey: runnerUp,
            margin: margin,
            isDecided: decided,
            evidenceEvents: evidenceEvents,
            lockedClassKey: lockedKey
        )
    }

    // MARK: - Internals

    private func applyDecay(to time: CFTimeInterval) {
        guard let last = lastTime, time > last, config.halfLife > 0 else {
            lastTime = max(lastTime ?? time, time)
            return
        }
        let factor = pow(0.5, (time - last) / config.halfLife)
        for (key, value) in weights {
            let decayed = value * factor
            if decayed < Self.weightFloor {
                weights.removeValue(forKey: key)
            } else {
                weights[key] = decayed
            }
        }
        lastTime = time
    }

    private func normalized(_ value: Double) -> Double {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return value / total
    }

    private func advanceLock(topKey: String, decided: Bool) {
        guard let current = lockedKey else {
            // Nothing locked yet: the first decided verdict becomes the stable label.
            // Until then there is nothing to protect, so the streak stays empty.
            if decided {
                lockedKey = topKey
            }
            challengerStreak = 0
            return
        }
        guard decided, topKey != current else {
            challengerStreak = 0
            return
        }
        challengerStreak += 1
        if challengerStreak >= max(config.switchConfirmations, 1) {
            lockedKey = topKey
            challengerStreak = 0
        }
    }
}
