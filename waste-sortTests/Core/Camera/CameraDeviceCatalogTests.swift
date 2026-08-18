import AVFoundation
import Testing
@testable import waste_sort

struct CameraDeviceCatalogTests {
    @Test func autoPreferenceConstantIsStable() {
        #expect(CameraPreference.autoID == "auto")
    }

    @Test func availableOptionsIncludesOnlyConnectedDevices() {
        let options = CameraDeviceCatalog.availableOptions()
        for option in options {
            #expect(!option.id.isEmpty)
            #expect(!option.name.isEmpty)
            if let device = CameraDeviceCatalog.device(forUniqueID: option.id) {
                #expect(device.isConnected)
            }
        }
    }

    @Test func resolveFallsBackWhenPreferenceMissing() {
        let resolved = CameraDeviceCatalog.resolveDevice(preferenceID: "missing-camera-id")
        let auto = CameraDeviceCatalog.resolveDevice(preferenceID: CameraPreference.autoID)
        #expect(resolved?.uniqueID == auto?.uniqueID)
    }
}
