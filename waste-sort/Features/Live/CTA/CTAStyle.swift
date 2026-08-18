import Foundation

/// Live HUD call-to-action shown when waste is detected.
enum CTAStyle: String, CaseIterable, Identifiable {
    case off
    case pulseLabel
    case dropdown
    case arrows
    case highlightSection

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .pulseLabel:
            return "Bin label pulse"
        case .dropdown:
            return "Dropdown"
        case .arrows:
            return "Arrows"
        case .highlightSection:
            return "Highlight section"
        }
    }
}

enum CTASpace {
    static let name = "liveCTA"
}
