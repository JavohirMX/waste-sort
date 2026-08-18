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
    /// Keep current primary until another box is this much larger.
    static let primaryAreaHysteresis: CGFloat = 1.25

    static let categoryLabelFont = Font.system(size: 14, weight: .semibold)
}
