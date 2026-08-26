import Foundation
import Testing
@testable import waste_sort

@Suite("Demo mode preset")
struct DemoModeSettingsTests {
    @MainActor
    private func makeSettings() -> (AppSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.demoMode.\(UUID())")!
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test("Demo is off by default")
    @MainActor
    func defaultsToOff() {
        let (settings, _) = makeSettings()
        #expect(settings.demoMode == false)
        #expect(settings.selectedModelName == WasteSortConfig.defaultModelName)
    }

    @Test("Turning Demo on stashes the production model and disables confirmation")
    @MainActor
    func enableSwapsModelAndTurnsOffConfirmation() {
        let (settings, _) = makeSettings()
        settings.selectedModelName = WasteSortModel.bestv35.resourceName
        settings.foundationConfirmationEnabled = true

        settings.demoMode = true

        #expect(settings.selectedModelName == WasteSortModel.demo.resourceName)
        #expect(settings.foundationConfirmationEnabled == false)
        #expect(settings.demoSavedModelName == WasteSortModel.bestv35.resourceName)
        #expect(settings.demoSavedFoundationConfirmation == true)
    }

    @Test("Turning Demo off restores the stashed model and confirmation")
    @MainActor
    func disableRestoresStash() {
        let (settings, _) = makeSettings()
        settings.selectedModelName = WasteSortModel.bestv34.resourceName
        settings.foundationConfirmationEnabled = true
        settings.demoMode = true

        settings.demoMode = false

        #expect(settings.demoMode == false)
        #expect(settings.selectedModelName == WasteSortModel.bestv34.resourceName)
        #expect(settings.foundationConfirmationEnabled == true)
        #expect(settings.demoSavedModelName.isEmpty)
    }

    @Test("Demo mode survives a relaunch")
    @MainActor
    func persists() {
        let (settings, defaults) = makeSettings()
        settings.selectedModelName = WasteSortModel.bestv33.resourceName
        settings.foundationConfirmationEnabled = true
        settings.demoMode = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.demoMode == true)
        #expect(reloaded.selectedModelName == WasteSortModel.demo.resourceName)
        #expect(reloaded.foundationConfirmationEnabled == false)
        #expect(reloaded.demoSavedModelName == WasteSortModel.bestv33.resourceName)
        #expect(reloaded.demoSavedFoundationConfirmation == true)
    }

    @Test("Reset to defaults turns Demo off and does not restore the stash")
    @MainActor
    func resetClearsDemoWithoutRestoringStash() {
        let (settings, _) = makeSettings()
        settings.selectedModelName = WasteSortModel.bestv32.resourceName
        settings.foundationConfirmationEnabled = true
        settings.demoMode = true

        settings.resetToDefaults()

        #expect(settings.demoMode == false)
        #expect(settings.selectedModelName == WasteSortConfig.defaultModelName)
        #expect(settings.foundationConfirmationEnabled == WasteSortConfig.defaultFoundationConfirmation)
        #expect(settings.demoSavedModelName.isEmpty)
        #expect(settings.demoSavedFoundationConfirmation == false)
    }

    @Test("Production model list excludes Demo")
    @MainActor
    func productionCasesSkipDemo() {
        #expect(WasteSortModel.productionCases.contains(.demo) == false)
        #expect(WasteSortModel.productionCases.contains(.bestv36))
        #expect(WasteSortModel.from(resourceName: "demo") == .demo)
    }
}
