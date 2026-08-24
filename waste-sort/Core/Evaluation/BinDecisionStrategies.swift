import Foundation

/// Faithful port of the pre-belief decision math that ships on `main`, kept verbatim
/// in spirit so bake-off results describe reality, not a strawman:
///
/// - display label: summed confidence per class inside a sliding 0.40 s window; the
///   challenger takes over only when its total is strictly greater (ties keep current);
/// - deposit verdict: lifetime cumulative confidence, argmax with ties broken toward
///   the lexicographically smallest key.
/// Faithful port of the pre-belief decision math that ships on `main`, kept verbatim
/// in spirit so bake-off results describe reality, not a strawman. Delegates to the
/// runtime `LegacyDecisionEngine`, which is also what the app runs when the decision
/// toggle is set to legacy — replays and production share one implementation.
nonisolated struct LegacyConfidenceStrategy: BinDecisionStrategy {
    let name = "legacy-main"

    private var engine = LegacyDecisionEngine()

    mutating func observe(_ frame: DecisionFrame) {
        guard let observation = frame.observations.max(by: { $0.conf < $1.conf }) else { return }
        engine.observe(
            classKey: observation.classKey,
            className: observation.classKey,
            conf: observation.conf,
            at: frame.offsetSeconds
        )
    }

    mutating func currentLabel() -> String {
        engine.label
    }

    mutating func finalVerdict() -> (key: String, wasFallback: Bool) {
        (engine.verdict().classKey, false)
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
