import SwiftUI

enum Theme {
    static let photoBackground = Color(red: 246 / 255, green: 247 / 255, blue: 242 / 255)
    static let barHeight: CGFloat = 56
    static let boxCornerRadius: CGFloat = 8
    static let boxStrokeWidth: CGFloat = 3
    static let boxFillOpacity: Double = 0.22
    static let badgeSize: CGFloat = 28
    static let hudInset: CGFloat = 24
    static let segmentDetectedOpacity: Double = 0.95
    static let segmentIdleOpacity: Double = 0.42
    static let animationDuration: Double = 0.2
    /// Keep current primary until another box is this much larger.
    static let primaryAreaHysteresis: CGFloat = 1.25

    static let categoryLabelFont = Font.system(size: 14, weight: .semibold)
}
