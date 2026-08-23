import Foundation
import Testing
@testable import waste_sort

struct BeliefEngineTests {
    private let t0: CFAbsoluteTime = 1_000

    @Test func singleClassHighConfidenceDecides() {
        let engine = BeliefEngine(config: .display)
        engine.observe(classKey: "organic", className: "organic", conf: 0.9, at: t0)
        engine.observe(classKey: "organic", className: "organic", conf: 0.9, at: t0 + 0.05)

        let state = engine.currentState(at: t0 + 0.10)

        #expect(state.isDecided)
        #expect(state.lockedClassKey == "organic")
        #expect(!state.isUncertain)
        #expect(state.margin == 1)
    }

    @Test func balancedAlternatingVotesStayUndecided() {
        let engine = BeliefEngine(config: .display)
        var time = t0
        for i in 0..<12 {
            let key = i.isMultiple(of: 2) ? "organic" : "residual"
            engine.observe(classKey: key, className: key, conf: 0.9, at: time)
            time += 0.05
        }

        let state = engine.currentState(at: time)

        #expect(state.evidenceEvents == 12)
        // Equal evidence for both classes: no verdict either way.
        #expect(!state.isDecided)
        #expect(state.isUncertain)
        #expect(state.margin < 0.15)
    }

    @Test func recentEvidenceDominatesStaleHistory() {
        let engine = BeliefEngine(config: BeliefConfig(
            halfLife: 0.5,
            decideThreshold: 0.55,
            decideMargin: 0.15,
            switchConfirmations: 2,
            minEvidenceEvents: 2
        ))
        // A long organic history...
        var time = t0
        for _ in 0..<20 {
            engine.observe(classKey: "organic", className: "organic", conf: 0.9, at: time)
            time += 0.05
        }
        // ...then a long gap that lets it decay away...
        time += 4 * 0.5
        // ...then an equally long residual run.
        for _ in 0..<20 {
            engine.observe(classKey: "residual", className: "residual", conf: 0.9, at: time)
            time += 0.05
        }

        let state = engine.currentState(at: time)

        #expect(state.topKey == "residual")
        let residualProbability = state.probabilities["residual"] ?? 0
        let organicProbability = state.probabilities["organic"] ?? 0
        #expect(residualProbability > organicProbability)
    }

    @Test func hysteresisHoldsLabelUntilChallengerSustainsLead() {
        let engine = BeliefEngine(config: BeliefConfig(
            halfLife: 2.0,
            decideThreshold: 0.55,
            decideMargin: 0.15,
            switchConfirmations: 3,
            minEvidenceEvents: 2
        ))
        var time = t0
        for _ in 0..<6 {
            engine.observe(classKey: "organic", className: "organic", conf: 0.95, at: time)
            time += 0.05
            _ = engine.currentState(at: time)
        }
        #expect(engine.currentState(at: time).lockedClassKey == "organic")

        // One strong challenger frame must NOT flip the lock...
        engine.observe(classKey: "residual", className: "residual", conf: 0.99, at: time)
        time += 0.05
        #expect(engine.currentState(at: time).lockedClassKey == "organic")

        // ...but three in a row must.
        while engine.currentState(at: time).lockedClassKey != "residual" {
            engine.observe(classKey: "residual", className: "residual", conf: 0.99, at: time)
            time += 0.05
            if time > t0 + 60 {
                Issue.record("lock never flipped")
                return
            }
        }
    }

    @Test func undecidedFrameResetsChallengerStreak() {
        let engine = BeliefEngine(config: BeliefConfig(
            halfLife: 5.0,
            decideThreshold: 0.55,
            decideMargin: 0.15,
            switchConfirmations: 2,
            minEvidenceEvents: 2
        ))
        var time = t0
        for _ in 0..<4 {
            engine.observe(classKey: "organic", className: "organic", conf: 0.95, at: time)
            time += 0.05
            _ = engine.currentState(at: time)
        }

        // Challenger wins once (streak 1), then a coin-flip frame resets the streak.
        engine.observe(classKey: "residual", className: "residual", conf: 0.99, at: time)
        time += 0.05
        _ = engine.currentState(at: time)
        engine.observe(classKey: "clean_inorganic", className: "clean_inorganic", conf: 0.55, at: time)
        time += 0.05
        _ = engine.currentState(at: time)
        engine.observe(classKey: "residual", className: "residual", conf: 0.99, at: time)
        time += 0.05

        #expect(engine.currentState(at: time).lockedClassKey == "organic")
    }

    @Test func minimumEvidenceGateBlocksSingleFrameVerdicts() {
        let engine = BeliefEngine(config: BeliefConfig(
            halfLife: 1.0,
            decideThreshold: 0.55,
            decideMargin: 0.15,
            switchConfirmations: 2,
            minEvidenceEvents: 2
        ))
        engine.observe(classKey: "organic", className: "organic", conf: 0.99, at: t0)

        let state = engine.currentState(at: t0 + 0.05)

        #expect(state.topKey == "organic")
        #expect(state.probabilities["organic"] == 1)
        #expect(!state.isDecided)
        #expect(state.isUncertain)
        #expect(state.lockedClassKey == nil)
    }

    @Test func decayRemovesForgottenClassesEntirely() {
        let engine = BeliefEngine(config: BeliefConfig(
            halfLife: 0.25,
            decideThreshold: 0.55,
            decideMargin: 0.15,
            switchConfirmations: 1,
            minEvidenceEvents: 2
        ))
        engine.observe(classKey: "organic", className: "organic", conf: 0.9, at: t0)
        engine.observe(classKey: "residual", className: "residual", conf: 0.8, at: t0 + 0.01)

        let muchLater = t0 + 5
        engine.observe(classKey: "clean_inorganic", className: "clean_inorganic", conf: 0.7, at: muchLater)
        let state = engine.currentState(at: muchLater + 0.01)

        #expect(state.probabilities.count == 1)
        #expect(state.probabilities["clean_inorganic"] != nil)
        #expect(state.runnerUpKey == nil)
    }

    @Test func tiesBreakLexicographically() {
        let engine = BeliefEngine(config: BeliefConfig(
            halfLife: 10.0,
            decideThreshold: 0.99,
            decideMargin: 0.50,
            switchConfirmations: 1,
            minEvidenceEvents: 2
        ))
        engine.observe(classKey: "residual", className: "residual", conf: 0.9, at: t0)
        engine.observe(classKey: "organic", className: "organic", conf: 0.9, at: t0 + 0.01)

        let state = engine.currentState(at: t0 + 0.02)

        #expect(state.topKey == "organic", "equal weight must resolve deterministically")
        #expect(state.runnerUpKey == "residual")
        #expect(!state.isDecided)
    }

    @Test func injectionCarriesExternalEvidenceWeight() {
        let engine = BeliefEngine(config: .deposit)
        engine.observe(classKey: "clean_inorganic", className: "clean_inorganic", conf: 0.6, at: t0)
        engine.inject(classKey: "residual", className: "residual", weight: 0.9, at: t0 + 0.02)

        let state = engine.currentState(at: t0 + 0.03)

        #expect(state.topKey == "residual")
        #expect(state.classNameByKey["residual"] == "residual")
    }

    @Test func depositPresetKeepsLongMemory() {
        let engine = BeliefEngine(config: .deposit)
        var time = t0
        for _ in 0..<5 {
            engine.observe(classKey: "organic", className: "organic", conf: 0.85, at: time)
            time += 0.05
        }
        // Two seconds of silence — far beyond the display half-life, well inside the
        // deposit one: the throw verdict must still remember the item.
        time += 2.0
        let state = engine.currentState(at: time)

        #expect(state.topKey == "organic")
        #expect(state.isDecided)
    }

    @Test func emptyEngineIsUncertainWithNoLeader() {
        let engine = BeliefEngine(config: .display)

        let state = engine.currentState(at: t0)

        #expect(state.topKey.isEmpty)
        #expect(state.probabilities.isEmpty)
        #expect(!state.isDecided)
        #expect(state.isUncertain)
    }

    @Test func resetClearsEverything() {
        let engine = BeliefEngine(config: .display)
        engine.observe(classKey: "organic", className: "organic", conf: 0.9, at: t0)
        engine.observe(classKey: "organic", className: "organic", conf: 0.9, at: t0 + 0.05)
        _ = engine.currentState(at: t0 + 0.06)

        engine.reset()
        let state = engine.currentState(at: t0 + 0.07)

        #expect(state.evidenceEvents == 0)
        #expect(state.lockedClassKey == nil)
        #expect(state.topKey.isEmpty)
    }
}
