import Foundation
import Testing
@testable import waste_sort

@Suite("Applied bin overrides store")
struct AppliedBinOverridesTests {

    private func isolatedDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "test-overrides-\(UUID().uuidString)"))
    }

    private func suggestion(
        itemClass: String = "clean_inorganic",
        binID: String = BinGuide.residual.id,
        sampleCount: Int = 14,
        agreementRate: Double = 0.86
    ) -> SuggestedOverride {
        SuggestedOverride(
            id: BinGuide.normalizedKey(itemClass),
            itemClass: itemClass,
            suggestedBinID: binID,
            currentStaticBinID: BinGuide.cleanInorganic.id,
            sampleCount: sampleCount,
            agreementRate: agreementRate,
            direction: .intoResidual
        )
    }

    @Test("Apply stores evidence and resolves through normalized keys")
    func applyAndLookup() throws {
        let store = AppliedBinOverrides(defaults: try isolatedDefaults())
        store.apply(suggestion(itemClass: "Chip Bag"))

        #expect(store.binID(forClass: "chip bag") == BinGuide.residual.id)
        #expect(store.binID(forClass: "CHIP-BAG") == BinGuide.residual.id)
        #expect(store.binID(forClass: "organic") == nil)

        let applied = store.all()
        #expect(applied.count == 1)
        #expect(applied.first?.itemClass == "chip_bag")
        #expect(applied.first?.sampleCount == 14)
        #expect(abs((applied.first?.agreementRate ?? 0) - 0.86) < 0.0001)
    }

    @Test("Remove restores nil; removeAll clears everything")
    func removal() throws {
        let store = AppliedBinOverrides(defaults: try isolatedDefaults())
        store.apply(suggestion(itemClass: "a_item"))
        store.apply(suggestion(itemClass: "b_item", binID: BinGuide.organic.id))

        store.remove(itemClassKey: "A-ITEM")
        #expect(store.binID(forClass: "a_item") == nil)
        #expect(store.binID(forClass: "b_item") == BinGuide.organic.id)

        store.removeAll()
        #expect(store.all().isEmpty)
        #expect(store.binID(forClass: "b_item") == nil)
    }

    @Test("Overrides persist across instances on the same defaults suite")
    func persistenceRoundTrip() throws {
        let defaults = try isolatedDefaults()
        let writer = AppliedBinOverrides(defaults: defaults)
        writer.apply(suggestion())

        let reader = AppliedBinOverrides(defaults: defaults)
        #expect(reader.binID(forClass: "clean_inorganic") == BinGuide.residual.id)
        let entry = try #require(reader.all().first)
        #expect(entry.binID == BinGuide.residual.id)

        // Removal is durable too.
        reader.remove(itemClassKey: "clean_inorganic")
        let afterRemoval = AppliedBinOverrides(defaults: defaults)
        #expect(afterRemoval.binID(forClass: "clean_inorganic") == nil)
    }

    @Test("Corrupt persisted data degrades to empty, not crash")
    func corruptDataSurvives() throws {
        let defaults = try isolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: "settings.appliedBinOverrides.v1")
        let store = AppliedBinOverrides(defaults: defaults)
        #expect(store.all().isEmpty)
    }
}
