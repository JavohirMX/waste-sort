import AppIntents
import Foundation

/// Siri / Shortcuts surface for hands-free kiosk control.
///
/// All intents hop to the shared singletons on the main actor; the recording
/// phase machine owns the actual transitions and reports failures via its
/// status message, mirrored here as the intent dialog.
struct SortlaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Toggle \(.applicationName) recording",
                "Start \(.applicationName) recording",
                "Stop \(.applicationName) recording"
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: ToggleVoiceGuidanceIntent(),
            phrases: [
                "Turn \(.applicationName) voice guidance on",
                "Turn \(.applicationName) voice guidance off",
                "Mute \(.applicationName)"
            ],
            shortTitle: "Voice Guidance",
            systemImageName: "speaker.wave.2"
        )
    }
}

/// Starts a recording if idle, stops it otherwise.
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Recording"
    static let description = IntentDescription(
        "Starts or stops a waste-sorting recording session.",
        categoryName: "Recording"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = RecordingController.shared
        if controller.isRecording || controller.phase == .starting {
            controller.stopRecording(userInitiated: true)
            return .result(dialog: "Stopping the recording.")
        }
        guard controller.canStart else {
            return .result(
                dialog: "Sortla can't record yet - open the app so the live camera is running."
            )
        }
        controller.startRecording()
        return .result(dialog: "Starting the recording.")
    }
}

/// Turns spoken deposit confirmations on or off.
struct ToggleVoiceGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Voice Guidance"
    static let description = IntentDescription(
        "Speaks which bin received each deposit.",
        categoryName: "Settings"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = AppSettings.shared
        settings.voiceGuidanceEnabled.toggle()
        let state = settings.voiceGuidanceEnabled ? "on" : "off"
        SpeechAnnouncer.shared.speak(state == "on" ? "Voice guidance on" : "Voice guidance off")
        return .result(dialog: "Voice guidance is now \(state).")
    }
}

/// Cycles to the next bundled set of Core ML weights without opening Settings.
struct SwitchModelIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Model"
    static let description = IntentDescription(
        "Cycles between the bundled YOLO weights.",
        categoryName: "Settings"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = AppSettings.shared
        if settings.demoMode {
            return .result(dialog: "Demo mode is on. Turn it off in Settings to switch models.")
        }
        let all = WasteSortModel.productionCases
        let current = all.first { $0.resourceName == settings.selectedModelName } ?? all[0]
        let next = all[(all.firstIndex(of: current)?.advanced(by: 1) ?? 0) % all.count]
        settings.selectedModelName = next.resourceName
        return .result(dialog: "Switched to \(next.displayName).")
    }
}
