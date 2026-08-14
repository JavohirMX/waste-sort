import Foundation

enum WasteSortModel: String, CaseIterable, Identifiable {
    case bestv31 = "best"
    case bestv32 = "bestv3.2"
    case bestv33 = "bestv3.3"

    var id: String { rawValue }

    /// Bundle resource name passed to Ultralytics (`best`, `bestv3.2`, `bestv3.3`).
    var resourceName: String { rawValue }

    var displayName: String {
        switch self {
        case .bestv31: return "best v3.1"
        case .bestv32: return "best v3.2"
        case .bestv33: return "best v3.3"
        }
    }

    static func from(resourceName: String) -> WasteSortModel {
        WasteSortModel(rawValue: resourceName) ?? .bestv31
    }
}
