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
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .onAppear {
            setIdleTimerDisabled(true)
            styleTabBar()
        }
        .onDisappear { setIdleTimerDisabled(false) }
        .onChange(of: scenePhase) { _, phase in
            setIdleTimerDisabled(phase == .active)
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private func styleTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings.shared)
}
