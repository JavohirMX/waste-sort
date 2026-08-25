import Foundation

/// How a bin's marker strip is printed.
///
/// The two styles exist to be compared on site, not in theory: which one survives the room's
/// lighting and the camera's white balance is not something this file can decide.
nonisolated enum BinMarkerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A row of equal black dashes along the rim, carrying nothing at all. Which bin it is
    /// comes from where the row appears, because the camera and the bins do not move.
    case dashes
    /// Saturated bars on white. The ink names the bin, so identity survives a distance at
    /// which the bar widths have already smeared into each other.
    case color
    /// Black bars on white. Nothing but the rhythm names the bin, so the rhythm has to be
    /// readable before a strip counts at all.
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashes: return "Dashes"
        case .color: return "Color"
        case .mono: return "Black & white"
        }
    }

    var detail: String {
        switch self {
        case .dashes:
            return "A row of equal dashes along the rim, with nothing encoded in it — the bin "
                + "is named by where the row appears. On fifteen frames of the site with "
                + "nothing installed it produced no false readings at all, and an arm across "
                + "the middle or a half-open drawer only lowers the count."
        case .color:
            return "Magenta, yellow, and cyan strips read from chroma. Measured against this "
                + "site, two of those three land on the colours the room is already full of — "
                + "blue liners and denim near cyan, the floor near yellow."
        case .mono:
            return "Black strips told apart by bar rhythm. Nothing false in this room, but bar "
                + "widths are what distance takes first, so it wants a large print."
        }
    }

    /// Whether a strip may be accepted on ink alone, without a readable rhythm.
    var allowsInkOnlyIdentity: Bool { self == .color }

    /// Whether this style is read by the dash scanner rather than the bar scanner.
    var usesDashRows: Bool { self == .dashes }
}

/// The bar rhythm printed on one strip: five bars, each one or two units wide, separated by
/// one-unit gaps.
///
/// Three properties are load-bearing, and all three are about what a camera loses first:
///
/// - **Palindromic.** A scan line crosses the strip from whichever side the camera happens to
///   be on, and nothing in the image says which end is which. A rhythm that reads the same
///   backwards removes the question instead of answering it.
/// - **Wide is exactly twice narrow.** Bar widths are the first thing distance and motion blur
///   take away. A 2:1 step survives far more smearing than the graded widths a real barcode
///   asks for.
/// - **The gaps are all one unit.** That makes the gaps the ruler: the scanner measures the
///   unit from them and never needs to know how far away the strip is.
nonisolated struct BinMarkerPattern: Equatable, Sendable, Identifiable {
    /// Width of each bar, in units. Always `barCount` entries, each 1 or 2.
    let barUnits: [Int]

    /// How many bars are wide. This is the whole identity: counting is far more robust than
    /// measuring, so two strips never differ by *where* a wide bar sits, only by how many.
    var id: Int { barUnits.filter { $0 == 2 }.count }

    static let barCount = 5
    static let gapUnits = 1

    static let single = BinMarkerPattern(barUnits: [1, 1, 2, 1, 1])
    static let double = BinMarkerPattern(barUnits: [2, 1, 1, 1, 2])
    static let triple = BinMarkerPattern(barUnits: [2, 1, 2, 1, 2])

    static let all: [BinMarkerPattern] = [single, double, triple]

    /// Total length of the printed strip, in units, gaps included.
    var totalUnits: Int {
        barUnits.reduce(0, +) + (Self.barCount - 1) * Self.gapUnits
    }

    var displayName: String { "Pattern \(id)" }

    /// The pattern whose bars match `widths`, or nil when nothing does.
    ///
    /// Deliberately an exact match rather than a nearest one: the scanner has already
    /// collapsed each bar to 1 or 2 with a wide tolerance, so anything that still fails to
    /// line up is not one of our strips, and guessing at it is how a wrong bin gets credited.
    static func matching(_ widths: [Int]) -> BinMarkerPattern? {
        all.first { $0.barUnits == widths }
    }

    static func withID(_ id: Int) -> BinMarkerPattern? {
        all.first { $0.id == id }
    }
}

/// One of the three printable inks, described where the detector actually measures: the
/// Rec. 601 chroma plane.
///
/// Chroma, not RGB, because chroma is what a shadow leaves alone. A bar in shade loses
/// luma and keeps its (Cb, Cr) almost exactly, which is the entire reason the color style
/// needs no exposure tuning.
nonisolated struct BinMarkerInk: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    /// Chroma centroid of the printed ink. Overridden per bin once the strip has been
    /// calibrated against the real print and the real light.
    let cb: Double
    let cr: Double
    /// sRGB for the printable sheet and the settings swatch.
    let red: Int
    let green: Int
    let blue: Int

    /// Distance from a sampled chroma pair to this ink, in the same units the config's
    /// tolerances are written in.
    func distance(cb sampleCb: Double, cr sampleCr: Double) -> Double {
        let dcb = sampleCb - cb
        let dcr = sampleCr - cr
        return (dcb * dcb + dcr * dcr).squareRoot()
    }

    /// The three process primaries, and not a matter of taste.
    ///
    /// Of every triple worth printing, these sit furthest apart in the chroma plane — the
    /// closest pair is 163 units apart, where a palette built from the app's own bin colors
    /// manages only 77, and its residual black has no chroma at all to measure. They are also
    /// the three colors a CMYK printer lays down with a single ink each, so nothing shifts
    /// between printers or between print runs.
    static let yellow = BinMarkerInk(
        id: "yellow", displayName: "Yellow",
        cb: 16, cr: 154,
        red: 255, green: 242, blue: 0
    )
    static let magenta = BinMarkerInk(
        id: "magenta", displayName: "Magenta",
        cb: 158, cr: 235,
        red: 236, green: 0, blue: 140
    )
    static let cyan = BinMarkerInk(
        id: "cyan", displayName: "Cyan",
        cb: 190, cr: 36,
        red: 0, green: 174, blue: 239
    )

    static let all: [BinMarkerInk] = [yellow, magenta, cyan]

    static func withID(_ id: String) -> BinMarkerInk? {
        all.first { $0.id == id }
    }
}

/// One of the three printable strips, and the unit a bin is actually bound to.
///
/// A slot pairs a rhythm with an ink rather than letting them be chosen separately, and that
/// is the point: under the color style the ink names the bin, under the mono style the rhythm
/// does, and pairing them means the same physical sticker answers either way. Switching styles
/// in settings then costs a reprint and nothing else — the bindings, the calibration, and the
/// zone setup all survive.
///
/// It also gives the color style a free cross-check. When both halves are readable they have
/// to agree; a strip whose ink says one bin and whose rhythm says another is not a strip we
/// printed, and is thrown away rather than guessed at.
nonisolated struct BinMarkerSlot: Equatable, Sendable, Identifiable {
    let index: Int

    var id: Int { index }
    var pattern: BinMarkerPattern { BinMarkerPattern.all[index] }
    var ink: BinMarkerInk { BinMarkerInk.all[index] }
    var displayName: String { "Marker \(index + 1)" }

    static let all: [BinMarkerSlot] = (0..<BinMarkerPattern.all.count).map(BinMarkerSlot.init)

    static func withIndex(_ index: Int) -> BinMarkerSlot? {
        all.indices.contains(index) ? all[index] : nil
    }

    static func withPatternID(_ patternID: Int) -> BinMarkerSlot? {
        all.first { $0.pattern.id == patternID }
    }

    static func withInkID(_ inkID: String) -> BinMarkerSlot? {
        all.first { $0.ink.id == inkID }
    }
}

extension BinMarkerDetection {
    /// Which printed strip this is, or nil when the two halves of its identity disagree.
    func slot(style: BinMarkerStyle) -> BinMarkerSlot? {
        switch style {
        case .dashes:
            // The dash style carries no identity in the marker at all — a row is bound to a
            // bin by where it appears. Nothing here can answer for it.
            return nil
        case .color:
            guard let inkID, let slot = BinMarkerSlot.withInkID(inkID) else { return nil }
            // A readable rhythm has to back the ink up. An unreadable one is allowed: that is
            // exactly the distance at which color is supposed to carry the answer alone.
            if let patternID, patternID != slot.pattern.id { return nil }
            return slot
        case .mono:
            guard let patternID else { return nil }
            return BinMarkerSlot.withPatternID(patternID)
        }
    }
}
