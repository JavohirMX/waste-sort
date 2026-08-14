import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            LiveCameraView()
                .tabItem {
                    Label("Live", systemImage: "camera.fill")
                }

            PhotoSortView()
                .tabItem {
                    Label("Photo", systemImage: "photo.on.rectangle")
                }
        }
        .tint(BinGuide.organic.color)
        .onAppear { setIdleTimerDisabled(true) }
        .onDisappear { setIdleTimerDisabled(false) }
        .onChange(of: scenePhase) { _, phase in
            setIdleTimerDisabled(phase == .active)
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings.shared)
}
