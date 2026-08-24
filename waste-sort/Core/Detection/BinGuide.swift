import SwiftUI

/// A top-bar segment's fill, as drawn in the design: a vertical gradient running from
/// `bottom` up to `top`, carried at `idleAlpha` while the bin is not in frame and at
/// `Theme.segmentDetectedOpacity` once it is.
nonisolated struct BinBarGradient: Hashable, Sendable {
    let bottom: Color
    let top: Color
    let idleAlpha: Double
}

nonisolated struct BinInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let displayName: String
    let category: String
    let bin: String
    /// Saturated color used for boxes and badges.
    let color: Color
    /// The top bar's gradient for this bin.
    let barGradient: BinBarGradient
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
        barGradient: BinBarGradient(
            bottom: Color(red: 53 / 255, green: 202 / 255, blue: 90 / 255),
            top: Color(red: 31 / 255, green: 122 / 255, blue: 54 / 255),
            idleAlpha: 0.18
        ),
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
        barGradient: BinBarGradient(
            bottom: Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255),
            top: .black,
            idleAlpha: 0.24
        ),
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
        // The design only draws this bin selected, so its idle alpha follows Organic's.
        barGradient: BinBarGradient(
            bottom: Color(red: 255 / 255, green: 204 / 255, blue: 0 / 255),
            top: Color(red: 204 / 255, green: 163 / 255, blue: 0 / 255),
            idleAlpha: 0.18
        ),
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
        barGradient: BinBarGradient(
            bottom: Color(red: 113 / 255, green: 113 / 255, blue: 122 / 255),
            top: Color(red: 68 / 255, green: 68 / 255, blue: 73 / 255),
            idleAlpha: 0.18
        ),
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

nonisolated extension TrackedDetection {
    /// The bin the kiosk should advise for this track right now.
    ///
    /// When the belief engine backs the label this is simply its bin; when it does
    /// not, guidance falls to `fallbackBinID` so an unsure item is pointed at the
    /// last-resort stream instead of a coin-flip guess. Deposit scoring mirrors this
    /// via `ZoneDeposit.classKey`, keeping advice and scoring consistent.
    var advisedBinID: String {
        beliefUncertain ? BinGuide.fallbackBinID : BinGuide.info(for: classKey).id
    }
}
