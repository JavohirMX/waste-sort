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
        instructions: "Food scraps, peels, garden and plant matter. No packaging."
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
                instructions: "Tissues, diapers, sanitary products, styrofoam, multilayer sachets, mixed or unrecognizable waste, and items soiled beyond rinsing. Also anything that is not"
        + "recyclable material."
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
                instructions: "Empty and dry plastic (bottles, cups, clean bags and film), metal, glass, clean paper, cardboard, and sticky notes. Default for recyclable types only when"
        + "leftover food, drink, sauce, or oil looks unlikely."
    )

    /// Overlay-only: a recyclable type that may still be dirty. Not a fourth physical bin,
    /// so it is omitted from `all`.
    static let dirtyRecyclable = BinInfo(
        id: "dirty_recyclable",
        title: "dirty recyclable",
        displayName: "DIRTY RECYCLABLE",
        category: "dirty_recyclable",
        bin: "Residual or Recyclable",
        color: Color(red: 39 / 255, green: 39 / 255, blue: 42 / 255),
        idleColor: Color(red: 82 / 255, green: 82 / 255, blue: 91 / 255),
        symbolName: "arrow.3.trianglepath",
                instructions: "Use when the item is recyclable material AND leftover food, drink, sauce, or oil looks possible — even if you are only about 40–50% sure. Prefer this over"
        + "recyclable whenever dirt is a real possibility. Rinse then recyclable; throw as-is then residual. Never a non-recyclable type."
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

    /// The stream unsure items are pointed at. Bali's regulation (Pergub 47/2019
    /// Pasal 6: what can be neither composted nor recycled goes to TPA), and a
    /// contaminated recyclable ruins its whole batch. So when the belief engine is
    /// unsure, the honest answer is residual — never a coin-flip guess at recycling.
    static let fallbackBinID = residual.id

    static func normalizedKey(_ className: String) -> String {
        className
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    static func bin(id: String) -> BinInfo {
        if id == dirtyRecyclable.id { return dirtyRecyclable }
        return all.first { $0.id == id } ?? unknown
    }

    static func info(for className: String) -> BinInfo {
        switch normalizedKey(className) {
        case "organic":
            return organic
        case "residual":
            return residual
        case "clean_inorganic", "cleaninorganic", "inorganic":
            return cleanInorganic
        case "dirty_recyclable", "dirtyrecyclable":
            return dirtyRecyclable
        default:
            return unknown
        }
    }

    static func isDirtyRecyclable(_ classKey: String) -> Bool {
        info(for: classKey).id == dirtyRecyclable.id
    }

    /// Category-bar / CTA bins this class should light. Dirty recyclable lights residual
    /// and recyclable together; unknown lights nothing.
    static func barBinIDs(for classKey: String) -> [String] {
        let id = info(for: classKey).id
        if id == dirtyRecyclable.id {
            return [residual.id, cleanInorganic.id]
        }
        if id == unknown.id { return [] }
        return [id]
    }

    static func isAcceptedDeposit(classKey: String, zoneBinID: String) -> Bool {
        let item = info(for: classKey).id
        if item == dirtyRecyclable.id {
            return zoneBinID == residual.id || zoneBinID == cleanInorganic.id
        }
        return item == zoneBinID
    }
}

extension TrackedDetection {
    /// The bin the system should point the user at for this track. When the belief
    /// engine cannot back a verdict, guidance falls to `fallbackBinID` so an unsure
    /// item is pointed at the last-resort stream instead of a coin-flip guess.
    /// Deposit scoring mirrors this via `ZoneDeposit.classKey`, keeping advice and
    /// scoring consistent.
    var advisedBinID: String {
        beliefUncertain ? BinGuide.fallbackBinID : BinGuide.bin(id: BinGuide.info(for: classKey).id).id
    }
}
