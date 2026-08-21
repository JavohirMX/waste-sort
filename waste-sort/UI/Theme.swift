import SwiftUI

enum Theme {
    static let photoBackground = Color(red: 246 / 255, green: 247 / 255, blue: 242 / 255)
    static let barHeight: CGFloat = 56
    static let boxCornerRadius: CGFloat = 8
    static let boxStrokeWidth: CGFloat = 3
    static let boxFillOpacity: Double = 0.22
    static let badgeSize: CGFloat = 28
    static let hudInset: CGFloat = 24
    /// Extra gap below the status bar so the category labels clear the clock.
    static let categoryBarTopGap: CGFloat = 20
    static let segmentDetectedOpacity: Double = 0.95
    static let segmentIdleOpacity: Double = 0.42
    static let animationDuration: Double = 0.2
    static let barCornerRadius: CGFloat = 14
    static let ctaPulseScale: CGFloat = 1.08
    static let ctaPulsePeriod: TimeInterval = 0.7
    static let ctaHighlightOpacity: Double = 0.24
    static let ctaHighlightPulseAmount: Double = 0.06
    static let ctaHighlightPulsePeriod: TimeInterval = 1.4
    static let ctaDropdownMessage = "Open the bin and throw it here."

    static let zoneStrokeWidth: CGFloat = 3
    static let zoneFillOpacity: Double = 0.14
    static let zoneFlashFillOpacity: Double = 0.55
    static let zoneHandleSize: CGFloat = 26
    static let zoneEditDash: [CGFloat] = [10, 6]
    /// An item is in the zone but has not dwelt long enough to count yet.
    static let zoneOccupiedDash: [CGFloat] = [6, 8]
    /// Dwell met — dropping it now would be recorded.
    static let zoneArmedDash: [CGFloat] = [14, 5]

    static let categoryLabelFont = Font.system(size: 14, weight: .semibold)

    // MARK: - Onboarding

    /// Page background across the onboarding flow.
    static let onboardingBackground = Color(red: 243 / 255, green: 247 / 255, blue: 244 / 255)
    /// The welcome screen's illustration panel sits on the grouped-background grey.
    static let onboardingPanelBackground = Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255)
    /// `Accents/Green` from the design — the same value as `Color(.systemGreen)`.
    static let onboardingAccent = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    /// Fill behind the two character illustrations.
    static let onboardingBlob = Color(red: 240 / 255, green: 238 / 255, blue: 210 / 255)
    static let onboardingCardCornerRadius: CGFloat = 20
    static let onboardingSubtitleOpacity: Double = 0.6
}

private struct HUDTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Scales the three top-bar category names only.
    var hudTextScale: CGFloat {
        get { self[HUDTextScaleKey.self] }
        set { self[HUDTextScaleKey.self] = newValue }
    }
}
