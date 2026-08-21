import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                LiveCameraView()
            } else {
                OnboardingFlow { settings.hasCompletedOnboarding = true }
            }
        }
        .onAppear { setIdleTimerDisabled(true) }
        .onDisappear { setIdleTimerDisabled(false) }
        .onChange(of: scenePhase) { _, phase in
            setIdleTimerDisabled(phase == .active)
            if phase != .active {
                recording.noteSceneBecameInactive()
                recording.flushAndSave()
            } else {
                recording.considerAutoStart()
            }
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings.shared)
        .environmentObject(RecordingController.shared)
}
