import Foundation
import Testing

@testable import waste_sort

@Suite("ZoneStore")
@MainActor
struct ZoneStoreTests {
    private func freshDefaults() throws -> UserDefaults {
        let suite = "ZoneStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func persist(_ zones: [DropZone], to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(zones), forKey: "zones.dropZones.v1")
    }

    @Test("loads persisted Inorganic zone name as Recyclable")
    func migratesLegacyInorganicName() throws {
        let defaults = try freshDefaults()
        var zones = DropZone.defaults(rotation: .zero, mirror: false)
        let index = try #require(zones.firstIndex { $0.binID == BinGuide.cleanInorganic.id })
        zones[index].name = "Inorganic"
        try persist(zones, to: defaults)

        let store = ZoneStore(defaults: defaults, rotation: .zero, mirror: false)
        let recyclable = try #require(store.zones.first { $0.binID == BinGuide.cleanInorganic.id })
        #expect(recyclable.name == "Recyclable")
    }

    @Test("leaves a custom recyclable zone name alone")
    func preservesCustomRecyclableName() throws {
        let defaults = try freshDefaults()
        var zones = DropZone.defaults(rotation: .zero, mirror: false)
        let index = try #require(zones.firstIndex { $0.binID == BinGuide.cleanInorganic.id })
        zones[index].name = "Plastic"
        try persist(zones, to: defaults)

        let store = ZoneStore(defaults: defaults, rotation: .zero, mirror: false)
        let recyclable = try #require(store.zones.first { $0.binID == BinGuide.cleanInorganic.id })
        #expect(recyclable.name == "Plastic")
    }
}
