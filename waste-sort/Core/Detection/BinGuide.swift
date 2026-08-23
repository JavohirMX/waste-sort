import SwiftUI

nonisolated struct BinInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let displayName: String
    let category: String
    let bin: String
    /// Saturated color used for active bar segments, boxes, and badges.
    let color: Color
    /// Softer tint used when the category is not currently detected.
    let idleColor: Color
    let symbolName: String
    let instructions: String
}

nonisolated enum BinGuide {
    static let organic = BinInfo(
        id: "organic",
        title: "organic",
        displayName: "ORGANIC",
        category: "organic",
        bin: "Green / Brown Bin (Organic)",
        color: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255),
        idleColor: Color(red: 107 / 255, green: 143 / 255, blue: 94 / 255),
        symbolName: "leaf.fill",
        instructions: "Food scraps, peels, plant matter. Keep free of plastic film and packaging."
    )

    static let residual = BinInfo(
        id: "residual",
        title: "residual",
        displayName: "RESIDUAL",
        category: "residual",
        bin: "Black / Grey Bin (Residual)",
        color: Color(red: 39 / 255, green: 39 / 255, blue: 42 / 255),
        idleColor: Color(red: 82 / 255, green: 82 / 255, blue: 91 / 255),
        symbolName: "trash.fill",
        instructions: "Soft plastic film, dirty packaging, tissues, mixed or contaminated items."
    )

    static let cleanInorganic = BinInfo(
        id: "clean_inorganic",
        title: "recyclable",
        displayName: "RECYCLABLE",
        category: "recyclable",
        bin: "Blue / Yellow Bin (Recyclable)",
        color: Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255),
        idleColor: Color(red: 196 / 255, green: 164 / 255, blue: 106 / 255),
        symbolName: "arrow.3.trianglepath",
        instructions: "Clean rigid plastic, metal cans, glass, clean paper/cardboard. Empty and dry."
    )

    static let unknown = BinInfo(
        id: "unknown",
        title: "unrecognized",
        displayName: "UNKNOWN",
        category: "unrecognized",
        bin: "General Bin",
        color: Color(red: 113 / 255, green: 113 / 255, blue: 122 / 255),
        idleColor: Color(red: 113 / 255, green: 113 / 255, blue: 122 / 255),
        symbolName: "questionmark.circle.fill",
        instructions: "No specific disposal guidance for this class."
    )

    static let all: [BinInfo] = [organic, residual, cleanInorganic]

    /// Where the system routes items it cannot place confidently.
    ///
    /// Bali's three-stream scheme treats residu as the last-resort stream (Pergub
    /// 47/2019 Pasal 6: what can be neither composted nor recycled goes to TPA), and
    /// a contaminated recyclable ruins its whole batch. So when the belief engine is
    /// unsure, the honest answer is residual — never a coin-flip guess at recycling.
    static let fallbackBinID = residual.id

    static func normalizedKey(_ className: String) -> String {
        className
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    static func bin(id: String) -> BinInfo {
        all.first { $0.id == id } ?? unknown
    }

    static func info(for className: String) -> BinInfo {
        switch normalizedKey(className) {
        case "organic":
            return organic
        case "residual":
            return residual
        case "clean_inorganic", "cleaninorganic", "inorganic":
            return cleanInorganic
        default:
            return unknown
        }
    }
}
