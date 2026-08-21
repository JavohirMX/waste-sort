import SwiftUI

/// Page 1 — the split welcome screen. Illustration on the left, copy and call to action
/// on the right. Collapses to a stacked layout when the window is too narrow to split.
struct WelcomeScreen: View {
    var onStart: () -> Void
    var onPrivacy: () -> Void

    @Environment(\.onboardingMetrics) private var m

    private let page = OnboardingPage.welcome

    var body: some View {
        if m.usesSplitLayout {
            HStack(spacing: 0) {
                illustration()
                    .frame(width: m.s(731))
                copyPanel
            }
        } else {
            VStack(spacing: 0) {
                illustration(fills: false)
                    .frame(height: m.size.height * 0.42)
                copyPanel
            }
        }
    }

    /// Fills its column in the split layout, where the panel matches the artwork's aspect.
    /// The stacked layout gets a short, wide slot instead, so the artwork is fitted there —
    /// filling it would crop the figures' heads.
    private func illustration(fills: Bool = true) -> some View {
        Image("ob-welcome")
            .resizable()
            .aspectRatio(contentMode: fills ? .fill : .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Theme.onboardingPanelBackground)
            .accessibilityHidden(true)
    }

    private var copyPanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: m.s(40))

            VStack(alignment: .leading, spacing: m.s(16)) {
                Text(page.title)
                    .font(BrandFont.display(m.s(64)))
                    .foregroundStyle(.black)

                Text(page.subtitle)
                    .font(BrandFont.body(m.s(26)))
                    .foregroundStyle(.black.opacity(Theme.onboardingSubtitleOpacity))
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: m.s(50))

            VStack(spacing: m.s(16)) {
                GlassCapsuleButton(
                    page.primaryTitle,
                    height: m.s(78),
                    fontSize: m.s(24),
                    action: onStart
                )

                if let secondary = page.secondaryTitle {
                    Button(action: onPrivacy) {
                        Text(secondary)
                            .font(BrandFont.body(m.s(20), weight: .medium))
                            .foregroundStyle(.black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, m.s(60))
        .padding(.vertical, m.s(80))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.onboardingBackground)
        .shadow(color: .black.opacity(0.25), radius: m.s(10.8), x: m.s(4))
    }
}

#Preview {
    WelcomeScreen(onStart: {}, onPrivacy: {})
        .environment(\.onboardingMetrics, OnboardingMetrics(size: OnboardingMetrics.reference))
}
