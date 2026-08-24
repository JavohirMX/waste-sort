import Foundation

/// Deterministic replay inputs for comparing bin-decision strategies.
///
/// A scenario is one physical object's sighting stream: every frame the model saw it,
/// what classes it shouted and how loudly, plus the ground-truth stream the item
/// actually belonged to. Timestamps are offsets from zero so replays never touch the
/// wall clock — same fixture in, same verdicts out, forever.
nonisolated struct DecisionObservation: Equatable, Sendable {
    let classKey: String
    let conf: Float

    init(classKey: String, conf: Float) {
        self.classKey = classKey
        self.conf = conf
    }
}

nonisolated struct DecisionFrame: Equatable, Sendable {
    /// Seconds since the object first appeared. Fixed 1/30 s steps mirror kiosk fps.
    let offsetSeconds: Double
    let observations: [DecisionObservation]

    init(offsetSeconds: Double, observations: [DecisionObservation]) {
        self.offsetSeconds = offsetSeconds
        self.observations = observations
    }
}

nonisolated struct DecisionScenario: Equatable, Sendable {
    let identifier: String
    let groundTruth: String
    let frames: [DecisionFrame]
    let note: String

    init(identifier: String, groundTruth: String, frames: [DecisionFrame], note: String = "") {
        self.identifier = identifier
        self.groundTruth = groundTruth
        self.frames = frames
        self.note = note
    }
}

/// How one strategy scored a scenario.
nonisolated struct ScenarioOutcome: Equatable, Sendable {
    let identifier: String
    /// Final bin verdict equals ground truth.
    let verdictCorrect: Bool
    /// Verdict was resolved by fallback (unsure) rather than decisive belief.
    let verdictWasFallback: Bool
    /// How many times the displayed label changed over the object's life.
    let displayFlips: Int
}

nonisolated struct StrategyReport: Equatable, Sendable {
    let strategyName: String
    let outcomes: [ScenarioOutcome]

    var correctCount: Int { outcomes.filter(\.verdictCorrect).count }
    var totalCount: Int { outcomes.count }
    var accuracy: Double { totalCount > 0 ? Double(correctCount) / Double(totalCount) : 0 }
    var totalDisplayFlips: Int { outcomes.reduce(0) { $0 + $1.displayFlips } }

    /// Verdicts that were wrong while claiming certainty — the dangerous category,
    /// because the kiosk user obeys them. An unsure-but-fallback-routed verdict is
    /// honest; this counts only the confident lies.
    var confidentWrongCount: Int {
        outcomes.filter { !$0.verdictCorrect && !$0.verdictWasFallback }.count
    }

    func outcome(for identifier: String) -> ScenarioOutcome? {
        outcomes.first { $0.identifier == identifier }
    }
}

/// One competitor in the bake-off. Implementations must be pure: no wall-clock reads,
/// no randomness — the evaluator owns all timestamps.
nonisolated protocol BinDecisionStrategy {
    var name: String { get }
    init()
    mutating func observe(_ frame: DecisionFrame)
    /// The label that would be on screen right now.
    mutating func currentLabel() -> String
    /// The frozen end-of-life verdict: (classKey, wasFallback).
    mutating func finalVerdict() -> (key: String, wasFallback: Bool)
}
