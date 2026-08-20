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
        #expect(store.staleTimeout == 2.0)
    }

    @Test("Persisting tag ID bindings")
    @MainActor
    func persistBindings() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.persist.\(UUID())")!
        let store = AprilTagBindingStore(defaults: testDefaults)

        let zone1 = UUID()
        let zone2 = UUID()
        store.setTagIDs([0, 1, 2], for: zone1)
        store.setTagID(7, for: zone2)

        #expect(store.bindings[zone1] == [0, 1, 2])
        #expect(store.bindings[zone2] == [7])

        // Reload fresh store instance from same defaults
        let reloadedStore = AprilTagBindingStore(defaults: testDefaults)
        #expect(reloadedStore.bindings[zone1] == [0, 1, 2])
        #expect(reloadedStore.bindings[zone2] == [7])
    }

    @Test("Preset group assignment and default tagIDs helper")
    @MainActor
    func presetAndDefaultTagIDs() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.preset.\(UUID())")!
        let store = AprilTagBindingStore(defaults: testDefaults)

        let zone1 = UUID()
        let zone2 = UUID()

        // Unset zone defaults to group based on index
        #expect(store.tagIDs(for: zone1, defaultIndex: 0) == [0, 1, 2])
        #expect(store.tagIDs(for: zone2, defaultIndex: 1) == [3, 4, 5])

        // Assign preset group 2 (tags 6, 7, 8)
        store.setTagPreset(groupIndex: 2, for: zone1)
        #expect(store.bindings[zone1] == [6, 7, 8])
        #expect(store.tagIDs(for: zone1, defaultIndex: 0) == [6, 7, 8])
    }

    @Test("Legacy single-int binding decoding migration")
    @MainActor
    func legacyMigration() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.legacy.\(UUID())")!
        let zone1 = UUID()
        let legacyDict: [UUID: Int] = [zone1: 4]
        let encoded = try! JSONEncoder().encode(legacyDict)
        testDefaults.set(encoded, forKey: "apriltag.bindings")

        let store = AprilTagBindingStore(defaults: testDefaults)
        #expect(store.bindings[zone1] == [4])
    }

    @Test("Pruning inactive zone IDs")
    @MainActor
    func pruneBindings() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.prune.\(UUID())")!
        let store = AprilTagBindingStore(defaults: testDefaults)

        let activeZone = UUID()
        let staleZone = UUID()
        store.setTagIDs([0, 1, 2], for: activeZone)
        store.setTagID(1, for: staleZone)

        store.prune(toActiveZoneIDs: [activeZone])

        #expect(store.bindings[activeZone] == [0, 1, 2])
        #expect(store.bindings[staleZone] == nil)
    }

    @Test("Persisting closed delay")
    @MainActor
    func persistStaleTimeout() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.timeout.\(UUID())")!
        let store = AprilTagBindingStore(defaults: testDefaults)
        store.staleTimeout = 1.4

        let reloadedStore = AprilTagBindingStore(defaults: testDefaults)
        #expect(reloadedStore.staleTimeout == 1.4)
    }

    @Test("Corrupted JSON safely defaults to empty bindings without crash")
    @MainActor
    func corruptedJSONRecovery() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.corrupt.\(UUID())")!
        testDefaults.set(Data("not-a-valid-json".utf8), forKey: "apriltag.bindings")

        let store = AprilTagBindingStore(defaults: testDefaults)
        #expect(store.bindings.isEmpty)
    }

    @Test("Toggles isEnabled and showDebugOverlay persist across store instances")
    @MainActor
    func persistToggles() {
        let testDefaults = UserDefaults(suiteName: "test.apriltag.toggles.\(UUID())")!
        let store = AprilTagBindingStore(defaults: testDefaults)
        store.isEnabled = false
        store.showDebugOverlay = true

        let reloadedStore = AprilTagBindingStore(defaults: testDefaults)
        #expect(reloadedStore.isEnabled == false)
        #expect(reloadedStore.showDebugOverlay == true)
    }
}
