import Foundation

/// Which decision math turns raw sightings into bin advice. Selectable at runtime so
/// the kiosk can A/B the belief pipeline against the pre-belief behavior that ships
/// on `main`.
nonisolated enum DecisionPipeline: String, CaseIterable, Sendable {
    /// Production engine: recency-weighted beliefs plus honest uncertainty that
    /// routes unsure items to the residual bin.
    case belief
    /// The pre-belief math: window vote for labels, lifetime confidence argmax for
    /// verdicts, no uncertainty concept.
    case legacy

    var displayName: String {
        switch self {
        case .belief: "Belief engine"
        case .legacy: "Legacy confidence"
        }
    }
}
