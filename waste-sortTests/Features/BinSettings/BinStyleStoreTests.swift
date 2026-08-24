import Foundation
import Testing

@testable import waste_sort

@Suite("BinStyleStore")
@MainActor
struct BinStyleStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "BinStyleStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("clamps labels to 16 characters")
    func clampLabel() {
        var custom = BinCustomization(
            binID: "organic",
            label: String(repeating: "a", count: 20),
            symbolName: "leaf.fill",
            colorToken: "green",
            order: 0
        )
        custom.clampLabel()
        #expect(custom.label.count == 16)
        #expect(BinCustomization.clamped(String(repeating: "b", count: 5)).count == 5)
    }

    @Test("persists and reloads customizations and site name")
    func persistLoad() {
        let defaults = freshDefaults()
        let store = BinStyleStore(defaults: defaults)
        store.siteName = "Test Site"
        var organic = store.customization(for: BinGuide.organic.id)
        organic.label = "Compost"
        organic.colorToken = BinColorToken.mint.rawValue
        organic.symbolName = BinIconOption.carrot.symbolName
        store.updateCustomization(organic)

        let reloaded = BinStyleStore(defaults: defaults)
        #expect(reloaded.siteName == "Test Site")
        let loaded = reloaded.customization(for: BinGuide.organic.id)
        #expect(loaded.label == "Compost")
        #expect(loaded.colorToken == "mint")
        #expect(loaded.symbolName == "carrot.fill")
        #expect(reloaded.orderedBins.first?.displayName == "COMPOST")
    }

    @Test("reorder remaps leftmost zone to the first bin without moving corners")
    func reorderRemapsZones() {
        let defaults = freshDefaults()
        let store = BinStyleStore(defaults: defaults)
        let zoneDefaults = UserDefaults(suiteName: "zones.\(UUID().uuidString)")!
        let zoneStore = ZoneStore(defaults: zoneDefaults, rotation: .zero, mirror: false)
        let originalCorners = zoneStore.zones.map(\.corners)

        // Reverse display order: recyclable, residual, organic.
        let reversed = [
            BinGuide.cleanInorganic.id,
            BinGuide.residual.id,
            BinGuide.organic.id
        ]
        store.reorder(
            orderedBinIDs: reversed,
            zoneStore: zoneStore,
            rotation: .zero,
            mirror: false
        )

        #expect(store.orderedBins.map(\.id) == reversed)
        #expect(zoneStore.zones.map(\.corners) == originalCorners)

        let byScreen = zoneStore.zones.sorted {
            BinStyleStore.screenX(of: $0, rotation: .zero, mirror: false)
                < BinStyleStore.screenX(of: $1, rotation: .zero, mirror: false)
        }
        #expect(byScreen.map(\.binID) == reversed)
    }
}
