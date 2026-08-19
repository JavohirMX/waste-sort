import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var recording: RecordingController

    var body: some View {
        LiveCameraView()
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
