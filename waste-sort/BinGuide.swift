import SwiftUI

struct BinInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let bin: String
    let color: Color
    let instructions: String
}

enum BinGuide {
    static let organic = BinInfo(
        id: "organic",
        title: "organic",
        category: "organic",
        bin: "Green / Brown Bin (Organic)",
        color: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255),
        instructions: "Food scraps, peels, plant matter. Keep free of plastic film and packaging."
    )

    static let residual = BinInfo(
        id: "residual",
        title: "residual",
        category: "residual",
        bin: "Black / Grey Bin (Residual)",
        color: Color(red: 82 / 255, green: 82 / 255, blue: 91 / 255),
        instructions: "Soft plastic film, dirty packaging, tissues, mixed or contaminated items."
    )

    static let cleanInorganic = BinInfo(
        id: "clean_inorganic",
        title: "clean inorganic",
        category: "clean inorganic",
        bin: "Blue / Yellow Bin (Clean Recyclables)",
        color: Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255),
        instructions: "Clean rigid plastic, metal cans, glass, clean paper/cardboard. Empty and dry."
    )

    static let unknown = BinInfo(
        id: "unknown",
        title: "unrecognized",
        category: "unrecognized",
        bin: "General Bin",
        color: Color(red: 113 / 255, green: 113 / 255, blue: 122 / 255),
        instructions: "No specific disposal guidance for this class."
    )

    static let all: [BinInfo] = [organic, residual, cleanInorganic]

    static func normalizedKey(_ className: String) -> String {
        className
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    static func info(for className: String) -> BinInfo {
        switch normalizedKey(className) {
        case "organic":
            return organic
        case "residual":
            return residual
        case "clean_inorganic", "cleaninorganic":
            return cleanInorganic
        default:
            return unknown
        }
    }
}
