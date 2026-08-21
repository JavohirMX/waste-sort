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

    /// A box whose category the on-device model is still working on: dimmed, dashed, and
    /// breathing, so it reads as "not settled yet" without competing with a real detection.
    static let confirmThinkingDash: [CGFloat] = [7, 5]
    static let confirmThinkingOpacity: Double = 0.40
    static let confirmThinkingPulseAmount: Double = 0.35
    static let confirmThinkingPulsePeriod: TimeInterval = 1.1
    /// A confirmed box is heavier than a plain one, so a locked category is visible at a
    /// glance across the room.
    static let confirmedStrokeWidth: CGFloat = boxStrokeWidth * 1.9
    static let confirmedFillOpacity: Double = 0.34
    /// One-shot flare at the moment the answer lands.
    static let confirmFlashDuration: TimeInterval = 0.5
    static let confirmFlashSpread: CGFloat = 10

    static let categoryLabelFont = Font.system(size: 14, weight: .semibold)
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
