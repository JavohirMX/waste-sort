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

    @Test("default recyclable label is Recyclable")
    func defaultRecyclableLabel() {
        let store = BinStyleStore(defaults: freshDefaults())
        let recyclable = store.customization(for: BinGuide.cleanInorganic.id)
        #expect(recyclable.label == "Recyclable")
        #expect(
            store.orderedBins.first { $0.id == BinGuide.cleanInorganic.id }?.displayName
                == "RECYCLABLE"
        )
    }

    @Test("loads persisted Inorganic as Recyclable and leaves a custom label alone")
    func migratesLegacyInorganicLabel() throws {
        let inorganicDefaults = freshDefaults()
        var inorganicItems = BinStyleStore.defaultCustomizations()
        let recyclableIndex = try #require(
            inorganicItems.firstIndex { $0.binID == BinGuide.cleanInorganic.id }
        )
        inorganicItems[recyclableIndex].label = "Inorganic"
        inorganicDefaults.set(
            try JSONEncoder().encode(inorganicItems),
            forKey: "binStyle.customizations.v1"
        )
        let migrated = BinStyleStore(defaults: inorganicDefaults)
        #expect(migrated.customization(for: BinGuide.cleanInorganic.id).label == "Recyclable")
        #expect(
            migrated.orderedBins.first { $0.id == BinGuide.cleanInorganic.id }?.displayName
                == "RECYCLABLE"
        )

        let customDefaults = freshDefaults()
        var customItems = BinStyleStore.defaultCustomizations()
        let customIndex = try #require(
            customItems.firstIndex { $0.binID == BinGuide.cleanInorganic.id }
        )
        customItems[customIndex].label = "Plastic"
        customDefaults.set(
            try JSONEncoder().encode(customItems),
            forKey: "binStyle.customizations.v1"
        )
        let custom = BinStyleStore(defaults: customDefaults)
        #expect(custom.customization(for: BinGuide.cleanInorganic.id).label == "Plastic")
        #expect(
            custom.orderedBins.first { $0.id == BinGuide.cleanInorganic.id }?.displayName
                == "PLASTIC"
        )
    }
}
