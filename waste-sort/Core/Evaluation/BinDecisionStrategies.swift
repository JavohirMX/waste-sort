import Foundation

/// Faithful port of the pre-belief decision math that ships on `main`, kept verbatim
/// in spirit so bake-off results describe reality, not a strawman:
///
/// - display label: summed confidence per class inside a sliding 0.40 s window; the
///   challenger takes over only when its total is strictly greater (ties keep current);
/// - deposit verdict: lifetime cumulative confidence, argmax with ties broken toward
///   the lexicographically smallest key.
nonisolated struct LegacyConfidenceStrategy: BinDecisionStrategy {
    let name = "legacy-main"

    /// Historical value from main (`WasteSortConfig.defaultClassLockWindow`, removed
    /// in the belief migration). Frozen so this port keeps replaying main's exact math.
    private static let historicWindow: CFTimeInterval = 0.40

    private var window: CFTimeInterval = LegacyConfidenceStrategy.historicWindow

    private struct Sample {
        let t: Double
        let classKey: String
        let conf: Float
    }

    private var samples: [Sample] = []
    private var lifetimeWeights: [String: Float] = [:]
    private(set) var label = ""

    mutating func observe(_ frame: DecisionFrame) {
        guard let observation = frame.observations.max(by: { $0.conf < $1.conf }) else { return }
        let sample = Sample(t: frame.offsetSeconds, classKey: observation.classKey, conf: observation.conf)
        samples.append(sample)
        lifetimeWeights[observation.classKey, default: 0] += observation.conf

        samples.removeAll { $0.t < frame.offsetSeconds - window }
        if label.isEmpty {
            label = sample.classKey
            return
        }
        guard let first = samples.first, let last = samples.last,
              last.t - first.t >= window
        else { return }

        var weights: [String: Float] = [:]
        for entry in samples {
            weights[entry.classKey, default: 0] += entry.conf
        }
        let currentWeight = weights[label] ?? 0
        // Same tie behavior as main's applyVote max closure.
        if let best = weights.max(by: { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }), best.key != label, best.value > currentWeight {
            label = best.key
        }
    }

    mutating func currentLabel() -> String {
        label
    }

    mutating func finalVerdict() -> (key: String, wasFallback: Bool) {
        // Lifetime argmax, ties to lexicographically smallest — exactly main's
        // TrackedObject.verdictClass.
        let best = lifetimeWeights.max { a, b in
            a.value == b.value ? a.key < b.key : a.value < b.value
        }
        return (best?.key ?? label, false)
    }
}

/// Adapter running the production belief wiring (display half-life for labels,
/// deposit half-life + fallback for verdicts) over replay frames.
nonisolated struct BeliefDecisionStrategy: BinDecisionStrategy {
    let name = "belief-engine"

    private var displayEngine = BeliefEngine(config: .display)
    private var depositEngine = BeliefEngine(config: .deposit)
    private(set) var lastLabel = ""
    /// Last sighting time — the verdict freezes here, exactly like
    /// ZoneDepositDetector freezes at vanish, so nothing decays after death.
    private var latestTime: CFTimeInterval = 0

    init() {}

    mutating func observe(_ frame: DecisionFrame) {
        let time = frame.offsetSeconds
        guard let observation = frame.observations.max(by: { $0.conf < $1.conf }) else { return }
        displayEngine.observe(classKey: observation.classKey, className: observation.classKey, conf: observation.conf, at: time)
        depositEngine.observe(classKey: observation.classKey, className: observation.classKey, conf: observation.conf, at: time)
        lastLabel = displayEngine.currentState(at: time).displayClassKey
        latestTime = max(latestTime, time)
    }

    mutating func currentLabel() -> String {
        lastLabel
    }

    mutating func finalVerdict() -> (key: String, wasFallback: Bool) {
        let state = depositEngine.currentState(at: latestTime)
        guard state.isDecided, !state.topKey.isEmpty else {
            return (BinGuide.fallbackBinID, true)
        }
        return (state.topKey, false)
    }
}
