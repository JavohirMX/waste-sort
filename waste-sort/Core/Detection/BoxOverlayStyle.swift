import SwiftUI

/// Where the detection badge sits on a bounding box.
enum BoxLabelPlacement: String, CaseIterable, Identifiable {
    case topLeading
    case top
    case topTrailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeading:
            return "Top left"
        case .top:
            return "Top"
        case .topTrailing:
            return "Top right"
        case .bottomLeading:
            return "Bottom left"
        case .bottom:
            return "Bottom"
        case .bottomTrailing:
            return "Bottom right"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeading:
            return .topLeading
        case .top:
            return .top
        case .topTrailing:
            return .topTrailing
        case .bottomLeading:
            return .bottomLeading
        case .bottom:
            return .bottom
        case .bottomTrailing:
            return .bottomTrailing
        }
    }

    /// Pushes corner badges slightly outside the box; center placements sit on the edge.
    func badgeOffset(distance: CGFloat) -> CGSize {
        switch self {
        case .topLeading:
            return CGSize(width: -distance, height: -distance)
        case .top:
            return CGSize(width: 0, height: -distance)
        case .topTrailing:
            return CGSize(width: distance, height: -distance)
        case .bottomLeading:
            return CGSize(width: -distance, height: distance)
        case .bottom:
            return CGSize(width: 0, height: distance)
        case .bottomTrailing:
            return CGSize(width: distance, height: distance)
        }
    }
}

/// Live/photo bounding-box badge contents and placement.
struct BoxOverlayStyle: Equatable {
    var showIcon: Bool
    var showCategory: Bool
    var showConfidence: Bool
    var placement: BoxLabelPlacement
    var badgeScale: CGFloat

    var showsBadge: Bool {
        showIcon || showCategory || showConfidence
    }

    var isIconOnly: Bool {
        showIcon && !showCategory && !showConfidence
    }

    static let `default` = BoxOverlayStyle(
        showIcon: true,
        showCategory: false,
        showConfidence: false,
        placement: .topTrailing,
        badgeScale: 1
    )
}
