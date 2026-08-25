import Testing
@testable import waste_sort

@Suite("PCC verdict parser")
struct PCCTransportsTests {

    @Test("Well-formed contract line parses all three fields")
    func wellFormedLine() {
        let parsed = PCCVerdictParser.parse(
            "bin=clean_inorganic; material=plastic bottle; rationale=Rinsed and dry so recyclable."
        )
        #expect(parsed?.bin == "clean_inorganic")
        #expect(parsed?.material == "plastic bottle")
        #expect(parsed?.rationale == "Rinsed and dry so recyclable.")
    }

    @Test("Rationale naming another bin can no longer flip the label (label-poisoning regression)")
    func rationaleMentioningAnotherBinDoesNotFlip() {
        // Old whole-line matching parsed this as clean_inorganic.
        let parsed = PCCVerdictParser.parse(
            "bin=residual; material=greasy box; rationale=Not clean_inorganic because sauce soaked in."
        )
        #expect(parsed?.bin == "residual")
    }

    @Test("Missing bin field is a failure, never a guess")
    func missingBinField() {
        #expect(PCCVerdictParser.parse("material=paper; rationale=looks clean") == nil)
        #expect(PCCVerdictParser.parse("OK") == nil)
        #expect(PCCVerdictParser.parse("") == nil)
    }

    @Test("Unknown bin token in the field is a failure, never a guess")
    func unknownBinToken() {
        #expect(PCCVerdictParser.parse("bin=hazardous; material=battery; rationale=no.") == nil)
    }

    @Test("Hyphenated model output normalizes to underscore taxonomy")
    func hyphenNormalization() {
        let parsed = PCCVerdictParser.parse("bin=dirty-recyclable; material=cup; rationale=Residue.")
        #expect(parsed?.bin == "dirty_recyclable")
    }

    @Test("Bin field is case-insensitive and tolerates spacing")
    func caseAndSpacingTolerance() {
        let parsed = PCCVerdictParser.parse("Bin =  ORGANIC; material=peel; rationale=Food.")
        #expect(parsed?.bin == "organic")
    }
}
