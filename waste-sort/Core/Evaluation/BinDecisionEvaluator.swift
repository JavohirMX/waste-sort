import Foundation

/// Runs scenario fixtures through competing bin-decision strategies and scores them
/// against ground truth.
///
/// This is the referee for "which decision layer ships": identical sighting streams go
/// to every strategy, timestamps come from the fixture (never the wall clock), and all
/// tie-breaks are deterministic — so a rerun of the same fixtures produces byte-identical
/// reports. Feed it synthetic scenarios here, or real captured frames later via the
/// per-frame `frame` events the session logger can emit.
nonisolated enum BinDecisionEvaluator {
    static func run(scenarios: [DecisionScenario], strategies: [any BinDecisionStrategy.Type]) -> [StrategyReport] {
        strategies.map { strategyType in
            let outcomes = scenarios.map { evaluate(scenario: $0, strategyType: strategyType) }
            return StrategyReport(strategyName: strategyType.init().name, outcomes: outcomes)
        }
    }

    static func evaluate(
        scenario: DecisionScenario,
        strategyType: any BinDecisionStrategy.Type
    ) -> ScenarioOutcome {
        var strategy = strategyType.init()
        var previousLabel: String?
        var flips = 0

        // Frames must replay in fixture order; sort defensively but deterministically.
        for frame in scenario.frames.sorted(by: { $0.offsetSeconds < $1.offsetSeconds }) {
            strategy.observe(frame)
            let label = strategy.currentLabel()
            if !label.isEmpty, let previousLabel, label != previousLabel {
                flips += 1
            }
            if !label.isEmpty {
                previousLabel = label
            }
        }

        let verdict = strategy.finalVerdict()
        return ScenarioOutcome(
            identifier: scenario.identifier,
            verdictCorrect: verdict.key == scenario.groundTruth,
            verdictWasFallback: verdict.wasFallback,
            displayFlips: flips
        )
    }

    /// Console-friendly bake-off table for logs and PR descriptions.
    static func table(_ reports: [StrategyReport]) -> String {
        var lines = ["strategy | accuracy | correct | display flips"]
        for report in reports {
            lines.append(
                "\(report.strategyName) | \(String(format: "%.1f%%", report.accuracy * 100)) | "
                    + "\(report.correctCount)/\(report.totalCount) | \(report.totalDisplayFlips)"
            )
        }
        return lines.joined(separator: "\n")
    }
}
