import SwiftUI

/// Maps design point values onto the actual screen.
///
/// Every number in the onboarding views is taken verbatim from the 1366×1024 Figma frames and
/// passed through `s(_:)`, which scales uniformly so the composition holds together on other
/// sizes instead of drifting apart the way independent per-element rules would.
struct OnboardingMetrics: Equatable {
    static let reference = CGSize(width: 1366, height: 1024)
    /// Below this width the welcome screen stacks instead of splitting into two columns.
    static let splitLayoutMinWidth: CGFloat = 900

    let size: CGSize
    let scale: CGFloat

    init(size: CGSize) {
        self.size = size
        let raw = min(size.width / Self.reference.width, size.height / Self.reference.height)
        // Clamped so a compact iPhone stays legible and a large iPad does not balloon.
        scale = min(max(raw, 0.42), 1.15)
    }

    /// Scales a design point value to the current screen.
    func s(_ value: CGFloat) -> CGFloat { value * scale }

    /// The welcome screen only splits when there is genuinely landscape room for two columns.
    /// A portrait iPad is wide enough in points but crops the illustration badly.
    var usesSplitLayout: Bool { size.width >= Self.splitLayoutMinWidth && size.width > size.height }
}

private struct OnboardingMetricsKey: EnvironmentKey {
    static let defaultValue = OnboardingMetrics(size: OnboardingMetrics.reference)
}

extension EnvironmentValues {
    /// Design-to-screen scaling for the onboarding flow.
    var onboardingMetrics: OnboardingMetrics {
        get { self[OnboardingMetricsKey.self] }
        set { self[OnboardingMetricsKey.self] = newValue }
    }
}
