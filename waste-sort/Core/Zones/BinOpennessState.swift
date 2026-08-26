import Foundation

/// Whether a physical bin is open, shut, or not yet known.
///
/// Lives on its own because two different detectors now produce it — AprilTags mounted inside
/// the bins, and printed marker strips — and `ZoneDepositDetector` consumes it without caring
/// which. Keeping it next to either detector would make the other one look like a guest.
nonisolated enum BinOpennessState: String, Codable, Sendable {
    case open
    case closed
    case unknown

    var acceptsItems: Bool { self == .open }

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .unknown: return "Unknown"
        }
    }
}
