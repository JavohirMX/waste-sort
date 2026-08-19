import Foundation
import Testing
@testable import waste_sort

@Suite("AprilTagBindingStore Tests")
struct AprilTagBindingStoreTests {
    @Test("Initial defaults and store values")
    @MainActor
    func storeDefaults() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.defaults.\(UUID())")!
        let store = AprilTagBindingStore(defaults: testDefaults)

        #expect(store.bindings.isEmpty)
        #expect(store.isEnabled == true)
        #expect(store.showDebugOverlay == false)
    }

    @Test("Persisting tag ID bindings")
    @MainActor
    func persistBindings() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.persist.\(UUID())")!
        let store = AprilTagBindingStore(defaults: testDefaults)

        let zone1 = UUID()
        let zone2 = UUID()
        store.setTagID(3, for: zone1)
        store.setTagID(7, for: zone2)

        #expect(store.bindings[zone1] == 3)
        #expect(store.bindings[zone2] == 7)

        // Reload fresh store instance from same defaults
        let reloadedStore = AprilTagBindingStore(defaults: testDefaults)
        #expect(reloadedStore.bindings[zone1] == 3)
        #expect(reloadedStore.bindings[zone2] == 7)
    }

    @Test("Pruning inactive zone IDs")
    @MainActor
    func pruneBindings() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.prune.\(UUID())")!
        let store = AprilTagBindingStore(defaults: testDefaults)

        let activeZone = UUID()
        let staleZone = UUID()
        store.setTagID(0, for: activeZone)
        store.setTagID(1, for: staleZone)

        store.prune(toActiveZoneIDs: [activeZone])

        #expect(store.bindings[activeZone] == 0)
        #expect(store.bindings[staleZone] == nil)
    }
}
