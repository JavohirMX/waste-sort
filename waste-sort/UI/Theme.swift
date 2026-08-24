import SwiftUI

enum Theme {
    static let photoBackground = Color(red: 246 / 255, green: 247 / 255, blue: 242 / 255)
    static let boxCornerRadius: CGFloat = 8
    static let boxStrokeWidth: CGFloat = 3
    static let boxFillOpacity: Double = 0.22
    static let badgeSize: CGFloat = 28
    static let hudInset: CGFloat = 24
    /// Extra gap below the status bar so the category labels clear the clock.
    static let categoryBarTopGap: CGFloat = 20
    /// Alpha a segment carries once its bin is in frame. Idle alpha is per bin, on
    /// `BinBarGradient`, because the design varies it (0.18 Organic, 0.24 Residual).
    static let segmentDetectedOpacity: Double = 0.80
    static let animationDuration: Double = 0.2

    static let ctaPulseScale: CGFloat = 1.08
    static let ctaPulsePeriod: TimeInterval = 0.7
    static let ctaHighlightOpacity: Double = 0.24
    static let ctaHighlightPulseAmount: Double = 0.06
    static let ctaHighlightPulsePeriod: TimeInterval = 1.4
    static let ctaDropdownMessage = "Open the bin and throw it here."
    /// Standing instruction along the bottom of the live screen.
    static let liveSortingHint = "Separate waste items to help us identify them."
    static let disclaimerHeight: CGFloat = 224
    static let disclaimerFontSize: CGFloat = 22

    static let zoneStrokeWidth: CGFloat = 3
    static let zoneFillOpacity: Double = 0.14
    static let zoneFlashFillOpacity: Double = 0.55
    static let zoneHandleSize: CGFloat = 26
    static let zoneEditDash: [CGFloat] = [10, 6]
    /// An item is in the zone but has not dwelt long enough to count yet.
    static let zoneOccupiedDash: [CGFloat] = [6, 8]
    /// Dwell met — dropping it now would be recorded.
    static let zoneArmedDash: [CGFloat] = [14, 5]

    /// Page background across the Stats and Bin Settings screens - `#DEEDE2` in the
    /// design, which draws both on the same light green rather than the two different
    /// creams the app had been using.
    static let statsBackground = Color(red: 222 / 255, green: 237 / 255, blue: 226 / 255)

    // MARK: - Bin Labels bar
    //
    // Every value below is 1:1 from the design. Its frame is 1366pt wide - a 12.9" iPad in
    // landscape - so these are already device points rather than a scale to divide down.
    // They move together with the "Category size" setting, which is why the bar is sized
    // from them rather than from a fixed height: at 100% it is exactly the design.

    /// Margin between the glass tray and the screen edges.
    static let barPageInset: CGFloat = 10
    /// The glass tray itself.
    static let barTrayHeight: CGFloat = 119
    static let barCornerRadius: CGFloat = 20
    /// Rim of glass left around the segments. Without it the tray has no visible material.
    static let barGlassInset: CGFloat = 16
    /// The three segments inside the tray.
    static let barSegmentRadius: CGFloat = 14
    static let barSegmentHPadding: CGFloat = 10
    static let barSegmentVPadding: CGFloat = 4
    static let barIconGap: CGFloat = 10
    /// Large Title/Emphasized - SF Pro Bold 34/41, the label tracked 0.6.
    static let barFontSize: CGFloat = 34
    static let barTracking: CGFloat = 0.6

    /// The whole bar node: tray plus its page margin.
    static func barHeight(scale: CGFloat) -> CGFloat {
        (barTrayHeight + barPageInset * 2) * scale
    }

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
    /// Scales the whole Bin Labels bar - tray, rim, radii, icons, and names together.
    var hudTextScale: CGFloat {
        get { self[HUDTextScaleKey.self] }
        set { self[HUDTextScaleKey.self] = newValue }
    }
}
