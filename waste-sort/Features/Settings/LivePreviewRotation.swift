import Foundation

enum LivePreviewRotation: Int, CaseIterable, Identifiable, Sendable {
    case zero = 0
    case ninety = 90
    case oneEighty = 180
    case twoSeventy = 270

    var id: Int { rawValue }

    var degrees: Double { Double(rawValue) }

    var swapsAxes: Bool {
        self == .ninety || self == .twoSeventy
    }

    var displayName: String {
        switch self {
        case .zero: return "Off (0°)"
        case .ninety: return "90°"
        case .oneEighty: return "180°"
        case .twoSeventy: return "270°"
        }
    }

    static func from(degrees: Int) -> LivePreviewRotation {
        LivePreviewRotation(rawValue: degrees) ?? .zero
    }
}
