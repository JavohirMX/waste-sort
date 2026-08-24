import Foundation

/// The decision math that shipped on `main`, kept verbatim so the runtime toggle
/// replays history rather than an imitation of it:
///
/// - display label: summed confidence per class inside a sliding 0.40 s window; a
///   challenger takes over only when its total is strictly greater (ties keep current);
/// - verdict: lifetime cumulative-confidence argmax, ties to the lexicographically
///   smallest key;
/// - no uncertainty concept — it always answers as if sure.
///
/// Single home for this logic: the bake-off's `LegacyConfidenceStrategy` delegates
/// here, so offline replays exercise exactly what production runs.
nonisolated struct LegacyDecisionEngine: Sendable {
    /// Historical value from main (`WasteSortConfig.defaultClassLockWindow`, removed
    /// in the belief migration). Frozen so this engine keeps replaying main's exact
    /// math even if tuning elsewhere drifts.
    static let historicWindow: CFTimeInterval = 0.40

    private struct Sample {
        let t: CFTimeInterval
        let classKey: String
        let conf: Float
    }

    private var samples: [Sample] = []
    private var lifetimeWeights: [String: Float] = [:]
    private var classNames: [String: String] = [:]
    private(set) var label = ""

    mutating func observe(classKey: String, className: String, conf: Float, at time: CFTimeInterval) {
        let sample = Sample(t: time, classKey: classKey, conf: conf)
        samples.append(sample)
        lifetimeWeights[classKey, default: 0] += conf
        classNames[classKey] = className

        samples.removeAll { $0.t < time - Self.historicWindow }
        if label.isEmpty {
            label = sample.classKey
            return
        }
        guard let first = samples.first, let last = samples.last,
              last.t - first.t >= Self.historicWindow
        else { return }

        var weights: [String: Float] = [:]
        for entry in samples {
            weights[entry.classKey, default: 0] += entry.conf
        }
        let currentWeight = weights[label] ?? 0
        // Same tie behavior as main's applyVote max closure: equal totals resolve
        // toward the larger key, and the incumbent only loses on strictly greater.
        if let best = weights.max(by: { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }), best.key != label, best.value > currentWeight {
            label = best.key
        }
    }

    /// Lifetime cumulative-confidence argmax — exactly main's TrackedObject.verdictClass.
    mutating func verdict() -> (classKey: String, className: String, weight: Float) {
        let best = lifetimeWeights.max { a, b in
            a.value == b.value ? a.key < b.key : a.value < b.value
        }
        let key = best?.key ?? label
        return (key, classNames[key] ?? key, best?.value ?? 0)
    }
}
