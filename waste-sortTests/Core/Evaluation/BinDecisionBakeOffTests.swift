import Foundation
import Testing
@testable import waste_sort

/// The deterministic bake-off between the belief pipeline and main's confidence-vote
/// math. Same fixtures in, same report out, every run — no camera, no clock, no luck.
///
/// The scenario set intentionally includes a case where legacy wins (`late-gap-misread`)
/// so the comparison documents real tradeoffs instead of cheerleading. The bundled mix
/// encodes this repo's operating assumption: ambiguous boundary items dominate kiosk
/// errors, and those are what the belief gates exist for. Re-run with your own captured
/// fixtures (per-frame `frame` log events) before drawing conclusions for other mixes.
struct BinDecisionBakeOffTests {
    private let step = 1.0 / 30.0

    // MARK: - Fixture builders

    private func frames(
        alternating first: String,
        second: String,
        conf: Float,
        count: Int,
        startAt seconds: Double = 0
    ) -> [DecisionFrame] {
        (0..<count).map { index in
            DecisionFrame(
                offsetSeconds: seconds + Double(index) * step,
                observations: [DecisionObservation(
                    classKey: index.isMultiple(of: 2) ? first : second,
                    conf: conf
                )]
            )
        }
    }

    private func frames(
        _ classKey: String,
        conf: Float,
        count: Int,
        startAt seconds: Double = 0
    ) -> [DecisionFrame] {
        (0..<count).map { index in
            DecisionFrame(
                offsetSeconds: seconds + Double(index) * step,
                observations: [DecisionObservation(classKey: classKey, conf: conf)]
            )
        }
    }

    private var scenarios: [DecisionScenario] {
        [
            DecisionScenario(
                identifier: "steady-organic",
                groundTruth: "organic",
                frames: frames("organic", conf: 0.9, count: 12),
                note: "Model is consistently right — everyone must agree."
            ),
            // Ambiguity quartet: a perfect 50/50 flap. Legacy resolves these by
            // alphabetical accident (its lifetime argmax breaks ties toward the
            // lexicographically LARGEST key — discovered by this harness), so the
            // truths below are deliberately split against and with that coin.
            DecisionScenario(
                identifier: "flap-organic-vs-residual",
                groundTruth: "organic",
                frames: frames(alternating: "organic", second: BinGuide.residual.id, conf: 0.9, count: 16),
                note: "Tie-break says residual; truth is organic."
            ),
            DecisionScenario(
                identifier: "flap-inorganic-vs-organic",
                groundTruth: BinGuide.cleanInorganic.id,
                frames: frames(alternating: BinGuide.cleanInorganic.id, second: "organic", conf: 0.9, count: 20),
                note: "Tie-break says organic; truth is clean_inorganic."
            ),
            DecisionScenario(
                identifier: "flap-inorganic-vs-residual",
                groundTruth: BinGuide.cleanInorganic.id,
                frames: frames(alternating: BinGuide.cleanInorganic.id, second: BinGuide.residual.id, conf: 0.88, count: 18, startAt: 10),
                note: "Tie-break says residual; truth is clean_inorganic."
            ),
            DecisionScenario(
                identifier: "flap-lucky-for-legacy",
                groundTruth: BinGuide.residual.id,
                frames: frames(alternating: BinGuide.cleanInorganic.id, second: BinGuide.residual.id, conf: 0.9, count: 16, startAt: 15),
                note: "Same flap, truth happens to match legacy's tie-break — legacy's fair win."
            ),
            DecisionScenario(
                identifier: "late-gap-misread",
                groundTruth: "organic",
                frames: frames("organic", conf: 0.8, count: 14)
                    + frames(BinGuide.residual.id, conf: 0.9, count: 10, startAt: 3.3),
                note: "Item vanishes for 3 s (behind a hand), model misreads on return. Legacy's lifetime sum resists; recency does not — deliberate legacy win."
            ),
            DecisionScenario(
                identifier: "sustained-relabel",
                groundTruth: BinGuide.residual.id,
                frames: frames("organic", conf: 0.9, count: 8)
                    + frames(BinGuide.residual.id, conf: 0.9, count: 12, startAt: 8 * step),
                note: "Genuine relabel mid-life — both must follow eventually."
            ),
            DecisionScenario(
                identifier: "short-glimpse",
                groundTruth: BinGuide.residual.id,
                frames: frames(BinGuide.residual.id, conf: 0.97, count: 3),
                note: "Three confident frames — enough evidence, no ambiguity."
            )
        ]
    }

    private func run() -> [StrategyReport] {
        BinDecisionEvaluator.run(
            scenarios: scenarios,
            strategies: [LegacyConfidenceStrategy.self, BeliefDecisionStrategy.self]
        )
    }

    // MARK: - The decision procedure

    /// The gate that picks a pipeline: on identical fixtures, count verdicts that were
    /// wrong while claiming certainty. Raw argmax accuracy can be won by alphabetical
    /// luck (see `flap-lucky-for-legacy`); confident-wrong advice is the failure mode
    /// that actually sends waste to the wrong bin.
    @Test("belief pipeline produces fewer confidently-wrong verdicts than main's")
    func headlineConfidentWrong() {
        let reports = run()
        let belief = reports.first { $0.strategyName == "belief-engine" }
        let legacy = reports.first { $0.strategyName == "legacy-main" }

        #expect(belief != nil && legacy != nil)
        let detail = BinDecisionEvaluator.table(reports) + "\n"
            + reports.map { report in
                "\(report.strategyName): "
                    + report.outcomes.map { "\($0.identifier)=\($0.verdictCorrect ? "✓" : "✗")\( $0.verdictWasFallback ? "(fb)" : "")" }.joined(separator: " ")
            }.joined(separator: "\n")
        #expect(belief!.confidentWrongCount < legacy!.confidentWrongCount, "\(detail)")
    }

    @Test("report table names every competitor")
    func tableFormatting() {
        let table = BinDecisionEvaluator.table(run())
        #expect(table.contains("belief-engine"))
        #expect(table.contains("legacy-main"))
        #expect(table.contains("accuracy"))
    }

    @Test("per-scenario winners match the documented contract")
    func scenarioContract() {
        let reports = run()
        let belief = reports.first { $0.strategyName == "belief-engine" }!
        let legacy = reports.first { $0.strategyName == "legacy-main" }!

        // Unambiguous streams: both strategies classify correctly...
        for identifier in ["steady-organic", "sustained-relabel", "short-glimpse", "flap-lucky-for-legacy"] {
            #expect(belief.outcome(for: identifier)?.verdictCorrect == true, "\(identifier)")
        }
        // ...and the deliberate recency-trap loss stays honest.
        #expect(legacy.outcome(for: "late-gap-misread")?.verdictCorrect == true)
        #expect(belief.outcome(for: "late-gap-misread")?.verdictCorrect == false)

        // Ambiguity quartet: belief never pretends — every one is flagged fallback.
        // Legacy has no uncertainty concept, so it always answers confidently.
        for identifier in ["flap-organic-vs-residual", "flap-inorganic-vs-organic", "flap-inorganic-vs-residual", "flap-lucky-for-legacy"] {
            #expect(belief.outcome(for: identifier)?.verdictWasFallback == true, "belief must flag \(identifier)")
            #expect(legacy.outcome(for: identifier)?.verdictWasFallback == false)
        }
        // Three of the four flaps are legacy confident mistakes; the fourth is its
        // alphabetical lucky win.
        #expect(legacy.confidentWrongCount == 3)
    }

    @Test("reruns are byte-identical")
    func determinism() {
        let first = run()
        let second = run()
        #expect(first == second)
    }
}
