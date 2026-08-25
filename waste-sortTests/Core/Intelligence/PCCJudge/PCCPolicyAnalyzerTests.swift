import Foundation
import Testing
@testable import waste_sort

@Suite("PCC policy analyzer")
struct PCCPolicyAnalyzerTests {

    private func answered(
        label: String,
        pccBin: String?,
        mappingFailed: Bool = false
    ) -> PCCVerdictRecord {
        PCCVerdictRecord(
            trackId: 1,
            cropFile: nil,
            yoloLabel: label,
            yoloConfidence: 0.5,
            beliefUncertain: true,
            beliefMargin: 0.1,
            engineBinID: BinGuide.fallbackBinID,
            pipeline: "belief",
            outcome: .answered,
            pccBinID: pccBin,
            pccRawBinLabel: pccBin,
            mappingFailed: mappingFailed
        )
    }

    private func skipped(
        _ label: String,
        _ outcome: PCCVerdictRecord.Outcome = .skippedQuota
    ) -> PCCVerdictRecord {
        PCCVerdictRecord(
            trackId: 1,
            cropFile: nil,
            yoloLabel: label,
            yoloConfidence: 0.5,
            beliefUncertain: true,
            beliefMargin: 0.1,
            engineBinID: BinGuide.fallbackBinID,
            pipeline: "belief",
            outcome: outcome
        )
    }

    @Test("Non-answered, mapping-failed, and empty-label records never count")
    func exclusions() {
        var records = (0..<8).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.residual.id) }
        // If any of these leaked into the evidence pool, the class would cross
        // the minimum-samples bar and produce a suggestion.
        records.append(skipped("clean_inorganic"))
        records.append(skipped("clean_inorganic", .cropFailed))
        // Would-be answered but the label could not be mapped to a bin.
        records.append(answered(label: "clean_inorganic", pccBin: nil, mappingFailed: true))
        // Twelve empty-label answers would otherwise dominate an "" class.
        for _ in 0..<12 { records.append(answered(label: "", pccBin: BinGuide.residual.id)) }

        #expect(PCCPolicyAnalyzer.suggestions(from: records) == [])
    }

    @Test("Confident (beliefUncertain=false) records are mined too (spec 003)")
    func confidentRecordsMined() throws {
        let confident = (0..<12).map { index -> PCCVerdictRecord in
            var record = answered(label: "tissue", pccBin: "clean_inorganic")
            record.beliefUncertain = false
            record.engineBinID = BinGuide.residual.id
            record.trackId = index
            return record
        }
        let suggestions = PCCPolicyAnalyzer.suggestions(from: confident)
        #expect(suggestions.contains { $0.id == "tissue" && $0.suggestedBinID == BinGuide.cleanInorganic.id })
    }

    @Test("Into-residual suggestion at standard thresholds")
    func intoResidual() throws {
        let records = (0..<9).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.residual.id) }
            + (0..<3).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.organic.id) }

        let suggestions = PCCPolicyAnalyzer.suggestions(from: records)
        #expect(suggestions.count == 1)
        let suggestion = try #require(suggestions.first)
        #expect(suggestion.id == "clean_inorganic")
        #expect(suggestion.suggestedBinID == BinGuide.residual.id)
        #expect(suggestion.currentStaticBinID == BinGuide.cleanInorganic.id)
        #expect(suggestion.sampleCount == 12)
        #expect(abs(suggestion.agreementRate - 0.75) < 0.0001)
        #expect(suggestion.direction == .intoResidual)
    }

    @Test("Dominant bin equal to static map yields no suggestion (no-op)")
    func noOpSuppressed() {
        let records = (0..<20).map { _ in answered(label: "residual", pccBin: BinGuide.residual.id) }
        #expect(PCCPolicyAnalyzer.suggestions(from: records) == [])
    }

    @Test("Below minimum samples is rejected")
    func belowMinSamples() {
        let records = (0..<11).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.residual.id) }
        #expect(PCCPolicyAnalyzer.suggestions(from: records) == [])
    }

    @Test("Below dominance is rejected")
    func belowDominance() {
        let records = (0..<8).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.residual.id) }
            + (0..<4).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.organic.id) }
        #expect(PCCPolicyAnalyzer.suggestions(from: records) == [])
    }

    @Test("Tied dominant bins carry no signal")
    func tieRejected() {
        let records = (0..<6).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.residual.id) }
            + (0..<6).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.organic.id) }
        #expect(PCCPolicyAnalyzer.suggestions(from: records) == [])
    }

    @Test("Out-of-residual needs the stricter bar: 14 strong samples fail, 30 pass")
    func outOfResidualAsymmetry() throws {
        // 13/14 clean_inorganic (93%) against static residual — still rejected.
        let weak = (0..<13).map { _ in answered(label: "residual", pccBin: BinGuide.cleanInorganic.id) }
            + (0..<1).map { _ in answered(label: "residual", pccBin: BinGuide.organic.id) }
        #expect(PCCPolicyAnalyzer.suggestions(from: weak) == [])

        // 26/30 (86.7%) clears the out-of-residual gate.
        let strong = (0..<26).map { _ in answered(label: "residual", pccBin: BinGuide.cleanInorganic.id) }
            + (0..<4).map { _ in answered(label: "residual", pccBin: BinGuide.organic.id) }
        let suggestions = PCCPolicyAnalyzer.suggestions(from: strong)
        #expect(suggestions.count == 1)
        let suggestion = try #require(suggestions.first)
        #expect(suggestion.direction == .outOfResidual)
        #expect(suggestion.suggestedBinID == BinGuide.cleanInorganic.id)
    }

    @Test("Lateral moves use standard thresholds")
    func lateral() {
        let records = (0..<9).map { _ in answered(label: "organic", pccBin: BinGuide.cleanInorganic.id) }
            + (0..<3).map { _ in answered(label: "organic", pccBin: BinGuide.residual.id) }
        let suggestions = PCCPolicyAnalyzer.suggestions(from: records)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.direction == .lateral)
    }

    @Test("Labels normalize before grouping and baseline lookup")
    func normalization() {
        let mixed = (0..<9).map { _ in answered(label: "Clean Inorganic", pccBin: BinGuide.residual.id) }
            + (0..<3).map { _ in answered(label: "clean-inorganic", pccBin: BinGuide.residual.id) }
        let suggestions = PCCPolicyAnalyzer.suggestions(from: mixed)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.id == "clean_inorganic")
        #expect(suggestions.first?.sampleCount == 12)
    }

    @Test("Unknown static classes can still be routed into residual")
    func unknownBaseline() {
        let records = (0..<12).map { _ in answered(label: "mystery_item", pccBin: BinGuide.residual.id) }
        let suggestions = PCCPolicyAnalyzer.suggestions(from: records)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.currentStaticBinID == BinGuide.unknown.id)
        #expect(suggestions.first?.direction == .intoResidual)
    }

    @Test("Diagnostic smoke records never count as routing evidence")
    func diagnosticsExcluded() {
        var records = (0..<8).map { _ in answered(label: "clean_inorganic", pccBin: BinGuide.residual.id) }
        // Same verdicts, but from the photo smoke screen: connectivity
        // evidence, not model-disagreement evidence. If these leaked into the
        // pool the class would cross the minimum-samples bar.
        for _ in 0..<20 {
            var smoke = answered(label: "clean_inorganic", pccBin: BinGuide.residual.id)
            smoke.pipeline = "photo-smoke"
            records.append(smoke)
        }
        #expect(PCCPolicyAnalyzer.suggestions(from: records) == [])
    }

    @Test("Suggestions sort by sample count desc, then id")
    func sorting() {
        var records = (0..<20).map { _ in answered(label: "aaa_item", pccBin: BinGuide.residual.id) }
        records += (0..<40).map { _ in answered(label: "zzz_item", pccBin: BinGuide.residual.id) }
        records += (0..<20).map { _ in answered(label: "bbb_item", pccBin: BinGuide.residual.id) }

        let ids = PCCPolicyAnalyzer.suggestions(from: records).map(\.id)
        #expect(ids == ["zzz_item", "aaa_item", "bbb_item"])
    }
}
