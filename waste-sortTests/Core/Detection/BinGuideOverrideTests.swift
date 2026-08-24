import Foundation
import Testing
@testable import waste_sort

@Suite("BinGuide learned-override layer")
struct BinGuideOverrideTests {

    private func withProvider(
        _ provider: @escaping @Sendable (String) -> String?,
        _ assertions: () throws -> Void
    ) throws {
        BinGuide.overrideProvider = provider
        defer { BinGuide.overrideProvider = nil }
        try assertions()
    }

    private let residualOnlyForCleanInorganic: @Sendable (String) -> String? = { key in
        key == "clean_inorganic" ? BinGuide.residual.id : nil
    }

    @Test("Applied override wins over static mapping")
    func precedence() throws {
        try withProvider(residualOnlyForCleanInorganic) {
            #expect(BinGuide.info(for: "clean_inorganic").id == BinGuide.residual.id)
            #expect(BinGuide.info(for: "Clean Inorganic").id == BinGuide.residual.id)
            #expect(BinGuide.info(for: "organic").id == BinGuide.organic.id)
        }
    }

    @Test("Provider unset restores pure static behavior")
    func clearedProvider() {
        #expect(BinGuide.info(for: "clean_inorganic").id == BinGuide.cleanInorganic.id)
        #expect(BinGuide.info(for: "residual").id == BinGuide.residual.id)
    }

    @Test("Invalid override target falls back to static taxonomy")
    func invalidTargetFallsBack() throws {
        let bogusTarget: @Sendable (String) -> String? = { key in
            key == "organic" ? "not_a_real_bin" : nil
        }
        try withProvider(bogusTarget) {
            #expect(BinGuide.info(for: "organic").id == BinGuide.organic.id)
        }
    }

    @Test("staticInfo bypasses overrides entirely")
    func staticBaselineUnaffected() throws {
        let residualEverything: @Sendable (String) -> String? = { _ in BinGuide.residual.id }
        try withProvider(residualEverything) {
            #expect(BinGuide.staticInfo(for: "clean_inorganic").id == BinGuide.cleanInorganic.id)
            #expect(BinGuide.staticInfo(for: "organic").id == BinGuide.organic.id)
            // While the public resolver does honor it.
            #expect(BinGuide.info(for: "organic").id == BinGuide.residual.id)
        }
    }

    @Test("Downstream resolvers see corrected routing")
    func downstreamResolvers() throws {
        try withProvider(residualOnlyForCleanInorganic) {
            #expect(BinGuide.barBinIDs(for: "clean_inorganic") == [BinGuide.residual.id])
            #expect(BinGuide.isAcceptedDeposit(classKey: "clean_inorganic", zoneBinID: BinGuide.residual.id))
            #expect(!BinGuide.isAcceptedDeposit(classKey: "clean_inorganic", zoneBinID: BinGuide.cleanInorganic.id))
        }
    }
}
