import SwiftUI
import UIKit

/// First-launch flow: seven pages that explain the three-bin system and walk through
/// mounting the iPad and the camera. Shown until `AppSettings.hasCompletedOnboarding` is set.
struct OnboardingFlow: View {
    var onFinish: () -> Void

    @State private var nav: OnboardingNavigator
    @Environment(\.openURL) private var openURL

    init(initialPage: OnboardingPage = .welcome, onFinish: @escaping () -> Void) {
        _nav = State(initialValue: OnboardingNavigator(page: initialPage))
        self.onFinish = onFinish
    }

    var body: some View {
        GeometryReader { geo in
            let metrics = OnboardingMetrics(size: geo.size)

            ZStack {
                Theme.onboardingBackground.ignoresSafeArea()

                // Only the welcome screen swaps wholesale — it is a different layout. Pages 2–7
                // share one scaffold that stays mounted, so the artwork inside it can move while
                // the copy and the capsule hold their positions.
                if nav.page == .welcome {
                    WelcomeScreen(onStart: advance, onPrivacy: openPrivacyPolicy)
                        .transition(pageTransition)
                } else {
                    OnboardingScaffold(
                        page: nav.page,
                        direction: nav.direction,
                        onPrimary: advance,
                        onSecondary: skipSetup
                    )
                    .transition(pageTransition)
                }

                if nav.page.showsChrome {
                    VStack {
                        OnboardingChrome(
                            canGoBack: nav.canGoBack,
                            onBack: goBack,
                            onSkip: finish
                        )
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
            .environment(\.onboardingMetrics, metrics)
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: nav.page)
        }
    }

    /// Matches the artwork's motion so the welcome-to-flow hand-off reads as the same gesture.
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: nav.direction == .forward ? .trailing : .leading)
                .combined(with: .opacity),
            removal: .opacity
        )
    }

    // MARK: - Navigation

    private func advance() {
        guard let next = nav.page.next else {
            finish()
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        nav.go(to: next)
    }

    /// "Already set up" on the station page — skip the two mounting steps.
    private func skipSetup() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        nav.go(to: .allSet)
    }

    private func goBack() {
        guard nav.canGoBack else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        nav.goBack()
    }

    private func finish() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onFinish()
    }

    private func openPrivacyPolicy() {
        // Inference runs entirely on device; the README is the current statement of that.
        guard let url = URL(string: "https://github.com/JavohirMX/waste-sort#privacy") else { return }
        openURL(url)
    }
}

#Preview {
    OnboardingFlow(onFinish: {})
        .environmentObject(AppSettings.shared)
}
