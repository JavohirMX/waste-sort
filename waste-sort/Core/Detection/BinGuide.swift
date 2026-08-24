import SwiftUI

/// The bin accents as the hi-fi draws them.
///
/// Every Figma frame pulled so far resolves bins to Apple's system accents, while the app
/// had shipped the Tailwind ramp (green-500 `#22c55e`, yellow-500 `#eab308`, zinc-800
/// `#27272a`). Boxes, badges, charts, chips and bar segments all read from here so a
/// detection box can never disagree with the segment it points at.
nonisolated enum BinPalette {
    /// `Accents/Green`, the value `Theme.onboardingAccent` also carries.
    static let organic = Color(red: 53 / 255, green: 202 / 255, blue: 90 / 255)
    static let organicShade = Color(red: 31 / 255, green: 122 / 255, blue: 54 / 255)
    static let residual = Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255)
    static let residualShade = Color.black
    /// `Accents/Yellow`.
    static let inorganic = Color(red: 255 / 255, green: 204 / 255, blue: 0 / 255)
    static let inorganicShade = Color(red: 204 / 255, green: 163 / 255, blue: 0 / 255)
}

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
        color: BinPalette.organic,
        barGradient: BinBarGradient(
            bottom: BinPalette.organic,
            top: BinPalette.organicShade,
            idleAlpha: 0.18
        ),
        symbolName: "leaf.fill",
        instructions: "Food scraps, tea bags, napkins"
    )

    static let residual = BinInfo(
        id: "residual",
        title: "residual",
        displayName: "RESIDUAL",
        category: "residual",
        bin: "Black / Grey Bin (Residual)",
        color: BinPalette.residual,
        barGradient: BinBarGradient(
            bottom: BinPalette.residual,
            top: BinPalette.residualShade,
            idleAlpha: 0.24
        ),
        symbolName: "trash.fill",
        instructions: "Food wrapper, tissue, sachets"
    )

    static let cleanInorganic = BinInfo(
        id: "clean_inorganic",
        title: "recyclable",
        displayName: "INORGANIC",
        category: "recyclable",
        bin: "Blue / Yellow Bin (Recyclable)",
        color: BinPalette.inorganic,
        // The design only draws this bin selected, so its idle alpha follows Organic's.
        barGradient: BinBarGradient(
            bottom: BinPalette.inorganic,
            top: BinPalette.inorganicShade,
            idleAlpha: 0.18
        ),
        symbolName: "arrow.3.trianglepath",
        instructions: "Bottles, cans, clean plastic"
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
