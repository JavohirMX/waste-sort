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
    /// Keep current primary until another box is this much larger.
    static let primaryAreaHysteresis: CGFloat = 1.25

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
}
