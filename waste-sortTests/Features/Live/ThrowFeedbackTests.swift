import SwiftUI
import Testing
@testable import waste_sort

@Suite("ThrowFeedback")
struct ThrowFeedbackMappingTests {
    @Test func correctDepositShowsDestinationBin() {
        #expect(ThrowFeedback.from(isCorrect: true, zoneBinID: BinGuide.organic.id) == .correct(binID: "organic"))
        #expect(ThrowFeedback.from(isCorrect: true, zoneBinID: BinGuide.residual.id) == .correct(binID: "residual"))
        #expect(
            ThrowFeedback.from(isCorrect: true, zoneBinID: BinGuide.cleanInorganic.id)
                == .correct(binID: "clean_inorganic")
        )
    }

    @Test func incorrectDepositTargetsTheDestinationSegment() {
        #expect(ThrowFeedback.from(isCorrect: false, zoneBinID: BinGuide.organic.id) == .incorrect(binID: "organic"))
        #expect(ThrowFeedback.from(isCorrect: false, zoneBinID: BinGuide.residual.id) == .incorrect(binID: "residual"))
        #expect(ThrowFeedback.from(isCorrect: false, zoneBinID: "residual").targetBinID == "residual")
    }

    @Test func correctEntersFromTopAndIncorrectFromLeading() {
        #expect(ThrowFeedback.correct(binID: "organic").insertionEdge == .top)
        #expect(ThrowFeedback.incorrect(binID: "organic").insertionEdge == .leading)
    }
}

@Suite("ThrowFeedbackGate")
struct ThrowFeedbackGateTests {
    @Test func presentReplacesFeedbackAndIssuesANewToken() {
        var gate = ThrowFeedbackGate()
        let first = gate.present(.correct(binID: "organic"))
        let second = gate.present(.incorrect(binID: "residual"))

        #expect(first != second)
        #expect(gate.token == second)
        #expect(gate.feedback == .incorrect(binID: "residual"))
    }

    @Test func staleDismissLeavesTheNewestFeedback() {
        var gate = ThrowFeedbackGate()
        let first = gate.present(.correct(binID: "organic"))
        _ = gate.present(.incorrect(binID: "residual"))

        gate.dismissIfCurrent(token: first)

        #expect(gate.feedback == .incorrect(binID: "residual"))
    }

    @Test func currentDismissClearsTheBanner() {
        var gate = ThrowFeedbackGate()
        let token = gate.present(.incorrect(binID: "organic"))

        gate.dismissIfCurrent(token: token)

        #expect(gate.feedback == nil)
    }

    @Test func dismissByObjectIDOnlyClearsThatObject() {
        let firstID = UUID()
        let secondID = UUID()
        var gate = ThrowFeedbackGate()
        _ = gate.present(.incorrect(binID: "organic"), objectID: firstID, persistWhilePresent: true)
        _ = gate.present(.incorrect(binID: "residual"), objectID: secondID, persistWhilePresent: true)

        gate.dismiss(objectID: firstID)
        #expect(gate.feedback == .incorrect(binID: "residual"))

        gate.dismiss(objectID: secondID)
        #expect(gate.feedback == nil)
    }
}

@Suite("Throw feedback sound setting")
struct ThrowFeedbackSoundSettingTests {
    @MainActor
    private func makeSettings() -> (AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.throwFeedback.\(UUID())")!
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test("Sounds are on by default")
    @MainActor
    func defaultsToOn() {
        let (settings, _) = makeSettings()
        #expect(settings.throwFeedbackSoundsEnabled == true)
    }

    @Test("The toggle survives a relaunch")
    @MainActor
    func persists() {
        let (settings, defaults) = makeSettings()
        settings.throwFeedbackSoundsEnabled = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.throwFeedbackSoundsEnabled == false)
    }

    @Test("Reset to defaults turns sounds back on")
    @MainActor
    func resetRestoresDefault() {
        let (settings, _) = makeSettings()
        settings.throwFeedbackSoundsEnabled = false

        settings.resetToDefaults()

        #expect(settings.throwFeedbackSoundsEnabled == true)
    }
}
