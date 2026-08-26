import CoreGraphics
import Foundation

/// What is printed in each dash.
nonisolated enum BinMarkerDashShape: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Plain rectangles. Found by run lengths alone, which is all a single scan line can see.
    case plain
    /// Each dash bent into a shallow V — leaning one way above the row's midline and the
    /// other way below it.
    ///
    /// The point is not decoration. A single scan line cannot tell a chevron from a rectangle,
    /// because a sheared bar is the same width at every height — so the finding pass is
    /// unchanged. What changes is what several lines together say: the row's offset ramps one
    /// way through the top half and the opposite way through the bottom.
    ///
    /// **A straight edge in the scene has one slope.** Wood grain, a counter lip, a sleeve —
    /// seen in perspective they all ramp steadily, and a third of the room's accidental rows
    /// do look sheared. None of them can reverse slope at a midline.
    ///
    /// What that is worth, measured on rendered prints slid out a dash at a time from behind a
    /// straight edge — which is what a drawer does — is **a third of the travel**:
    ///
    ///     dashes clear of the edge │  3    4    5    6
    ///     chevron                  │  —   ✓✓   ✓✓   ✓✓
    ///     plain, same printed height│  —    —   ½    ✓✓
    ///
    /// Neither reads anything false in fifteen frames of the empty room. Like for like — at
    /// the lowest run threshold where each first reads nothing false, seven against eight —
    /// the shape is worth one dash; the other dash comes from the margin the plain profiles
    /// carry, and that margin is what the shape makes unnecessary.
    ///
    /// An earlier prototype claimed three dashes against six. It had scored its own detection
    /// on a synthetic canvas whose row edges were exact; on a real raster, where the top and
    /// bottom scan lines cut half-covered anti-aliased ink, the same threshold reads the room
    /// as readily as the marker.
    ///
    /// The cost is the row stride: telling the two halves apart needs six scan lines, so this
    /// always scans every line, where a plain row of the same printed height scans every
    /// second one. Measured at 30 ms a frame against 17, on a device shared with the model.
    case chevron

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plain: return "Plain"
        case .chevron: return "Chevron"
        }
    }

    var detail: String {
        switch self {
        case .plain:
            return "Rectangles. Any height, but the row itself has to be long enough to be "
                + "unmistakable."
        case .chevron:
            return "Each dash bent into a V, which no straight edge in the room can "
                + "counterfeit. Opens on 4 dashes where a plain row of the same height needs "
                + "6 — a third less drawer travel — for about twice the time per frame."
        }
    }

    /// Alternating runs a stretch needs before it is even considered.
    ///
    /// Lower for a chevron because the run count is no longer carrying the discrimination on
    /// its own — the shape shares it. Measured on fifteen site frames against sixteen rendered
    /// prints, at the row stride of one that both settings use:
    ///
    ///     runs  dashes │ plain: read  invented │ chevron: read  invented
    ///        5       3 │      16 / 16      185 │       16 / 16       28
    ///        6       4 │      16 / 16       27 │       16 / 16        3
    ///        7       4 │      16 / 16        5 │       16 / 16        0
    ///        8       5 │      12 / 16        0 │       12 / 16        0
    ///
    /// Seven is where the chevron reads every print and the room produces nothing; a plain row
    /// has to go to eight for that, and eight is a dash further out of the drawer. So the
    /// shape is worth one dash of travel at equal printed height — not the three an earlier
    /// prototype claimed, which had scored its detection on a synthetic canvas where the row's
    /// edges were exact.
    var minRuns: Int { self == .chevron ? 7 : 10 }

    /// Scan lines needed to tell the two halves apart.
    var minLines: Int { self == .chevron ? 6 : 3 }

    var requiresShapeCheck: Bool { self == .chevron }
}

/// How short the printed row is allowed to be, and what that costs.
///
/// One setting rather than two knobs, because the two only move together. A finer row stride is
/// what lets the sticker be shorter — three scan lines must cross it, so its printed height is
/// the stride times three — but finer also means more scan lines, and more scan lines means
/// more chances for the room to produce a stretch that looks like a row. The way to pay that
/// back is a longer printed row, so the shorter setting also costs a dash.
///
/// Measured on fifteen frames of the site with nothing installed, at 8 px per cm:
///
///     setting     height  stride  dashes  travel at 8 mm   cost   false rows
///     tall        15.0mm       4       5           72 mm   10 ms           0
///     thin         7.5mm       2       6           88 mm   17 ms           0
///     very thin    3.8mm       1       7          104 mm   31 ms           0
///
/// Every row of that table is clean, so the choice is not about false readings. It is that
/// **taller is better on every axis a bin cares about** — it opens sooner and costs less of
/// the frame — and the only reason to go shorter is a rim that cannot give up the height.
/// Prefer the tallest that fits.
///
/// Each dash count above is the *first* one that reads nothing false, which is what makes it a
/// floor rather than a preference. Sweeping the threshold across the same fifteen frames:
///
///     dashes to open │  tall   thin   very thin
///                  3 │   442   1070        1553
///                  4 │     6     43         164
///                  5 │     0      3          10
///                  6 │     0      0           1
///                  7 │     0      0           0
///
/// The cliff is one dash wide. That is why `BinMarkerStore.dashesToOpen` follows the height
/// whenever the height changes rather than being carried across — a threshold measured against
/// one row stride means nothing against another.
///
/// Very thin is on the list for the printed sheets it does not have: at 3.8 mm it is asking to
/// read a sticker shorter than anything currently printable, and against the 14 mm and 18 mm
/// strips on the dash sheet it is simply the slowest and least sensitive way to read them. It
/// is kept because the numbers above come from rendered frames, and whether 31 ms a pass is
/// survivable next to the model on the actual iPad is not something a render can answer.
nonisolated enum BinMarkerDashProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case tall
    case thin
    /// Raw value kept from when this was called hairline, so a device already set to it stays
    /// set to it. What it is called on screen is `displayName`'s business.
    case veryThin = "hairline"

    var id: String { rawValue }

    var rowStride: Int {
        switch self {
        case .tall: return 4
        case .thin: return 2
        case .veryThin: return 1
        }
    }

    /// Raised in step with the stride, because the extra scan lines have to be paid for.
    var minRuns: Int {
        switch self {
        case .tall: return 8
        case .thin: return 10
        case .veryThin: return 12
        }
    }

    /// Printed dashes that must clear the counter edge. A clean row of N dashes reads as
    /// 2N−1 runs, so this is `ceil((minRuns + 1) / 2)`.
    var dashesNeeded: Int { (minRuns + 2) / 2 }

    var displayName: String {
        switch self {
        case .tall: return "Tall"
        case .thin: return "Thin"
        case .veryThin: return "Very thin"
        }
    }

    var detail: String {
        switch self {
        case .tall:
            return "Wants about 15 mm of printed height. Opens on 5 dashes and is the lightest "
                + "of the three on frame rate — use it wherever the rim allows."
        case .thin:
            return "About 7.5 mm, for a rim that cannot give up more. Costs a dash to open, "
                + "and about half again the time a frame."
        case .veryThin:
            return "About 3.8 mm. Nothing printed is this short, so against the current strips "
                + "it only costs — 7 dashes to open and 31 ms a frame. Here to be measured on "
                + "the device rather than argued about."
        }
    }
}

/// Knobs for the dash-row scanner.
///
/// Every threshold here was set against fifteen frames of the real site rather than against a
/// synthetic scene, which is the whole reason this design exists.
nonisolated struct BinMarkerDashConfig: Equatable, Sendable {
    /// Alternating runs a stretch needs before it counts. Nine is five dashes and four gaps.
    ///
    /// This single number is what separates a marker from a room, and it is set by measurement
    /// on the site's own frames with nothing installed: at five runs they produced 39 false
    /// rows, at six 7, at seven 3, and at **eight, none at all**.
    ///
    /// Counted in dashes rather than runs, eight is five: a clean row of N dashes reads as
    /// 2N−1 runs, because the printed white margin at each end merges into the surrounding
    /// background and is cut off by the width-agreement check rather than counted. So the
    /// deployment rule is that a drawer reads open once **five dashes** have cleared the
    /// counter edge — and a row caught mid-gap by that edge can satisfy it with four dashes
    /// and the partial gap beside them, which is the one place the eighth run earns its keep.
    ///
    /// Going lower is not a tuning question. At seven runs the room produces a false row every
    /// eighth frame even inside a rim-sized band, which for a gate means flickering open. To
    /// trigger sooner, print the dashes smaller rather than lowering this: five dashes at a
    /// 4 mm pitch clear the edge in half the travel that five at 8 mm need, and full-resolution
    /// sampling is what makes 4 mm readable.
    var minRuns: Int = BinMarkerDashProfile.thin.minRuns

    /// Widest run over narrowest, across a stretch. Nothing compares one run to another to
    /// extract a value — they only have to agree, which is what makes the row unmistakable
    /// without making it fragile.
    ///
    /// Also what keeps a wide-angle lens survivable: a row bending away from the camera has
    /// its far end compressed, and the stretch simply ends there instead of being rejected.
    var maxPitchSpread: Double = 1.8

    /// A dash narrower than this is below the resolution where anything can be said about it.
    /// Two samples is enough — measured, and far below what the bar rhythm needed, because
    /// nothing here divides one width by another.
    var minPitchSamples: Double = 2
    var maxPitchSamples: Double = 60

    /// Runs shorter than this are folded into their neighbour first: the sub-pixel edge
    /// between a dash and the paper otherwise fences every dash off from its neighbours.
    var minRunSamples: Int = 2

    /// How short the sticker may be printed, and what it costs. Sets `rowStride` and
    /// `minRuns` together, because those two only ever move together.
    var profile: BinMarkerDashProfile = .thin {
        didSet { applyProfileAndShape() }
    }

    /// What is printed in each dash. A chevron is verified across scan lines rather than
    /// along one, which is what lets `minRuns` fall so far.
    var shape: BinMarkerDashShape = .plain {
        didSet { applyProfileAndShape() }
    }

    private mutating func applyProfileAndShape() {
        rowStride = shape == .chevron ? 1 : profile.rowStride
        minRuns = shape == .chevron ? shape.minRuns : profile.minRuns
        minLines = shape.minLines
    }

    /// Printed dashes that must clear the counter edge for this configuration.
    var dashesNeeded: Int { (minRuns + 2) / 2 }

    /// The inverse: runs to demand so that `dashes` printed dashes are enough.
    ///
    /// A clean row of N dashes reads as 2N−1 runs, and this asks for one less than that on
    /// purpose. The row the counter edge catches mid-gap shows N dashes and the partial gap
    /// beside them — 2N−2 runs — and that is exactly the moment the drawer is meant to read
    /// open, so the threshold is written for it rather than against it.
    static func runs(forDashes dashes: Int) -> Int { max(2, dashes * 2 - 2) }

    /// How far the dash threshold may be moved by hand. Three is where a "row" stops being a
    /// rhythm at all; ten is a longer row than any sheet prints.
    static let dashesToOpenRange = 3...10

    /// Every Nth row, and separately every Nth column — because the two passes are not doing
    /// the same job and should not pay the same price.
    ///
    /// A row of dashes lying flat is read *along* by the horizontal pass, so the number of
    /// horizontal scan lines that cross it is its printed height divided by `rowStride`: that
    /// one number sets how thin the sticker may be. The vertical pass crosses such a row on
    /// its short side and gets a single run out of it — no alternation, nothing to read. It
    /// earns its place only by catching a row mounted the other way round, which is worth
    /// keeping and not worth paying much for.
    ///
    /// So rows are scanned finely and columns coarsely.
    var rowStride: Int = BinMarkerDashProfile.thin.rowStride
    var columnStride: Int = 8
    var minLines: Int = 3
    /// Local light-to-dark spread a scan line needs before its samples mean anything.
    var minContrast: Int = 40
    /// Half-width of the sliding window the threshold is taken from. Costs nothing to widen —
    /// the sliding extreme is linear in the line length whatever this is — so it is set by
    /// what it should span (several dashes) rather than by what it can afford.
    var windowRadius: Int = 24

    /// How far each half-fit may stray from its own line before the fit is called noise.
    var maxShapeResidual: Double = 1.2
    /// How steep each half must lean. Below this the row is straight, not bent.
    var minShapeSlope: Double = 0.4
    /// How far the two halves' steepness may differ, as a fraction of the steeper one.
    ///
    /// A fraction rather than an absolute, because slope is not a fixed quantity: a chevron
    /// printed with a deeper bend, or read from closer, ramps faster in both halves at once.
    /// Half a pixel per line is a quarter of the difference at a slope of 2 and more than the
    /// whole of it at a slope of 0.4 — the same number meaning two different tests.
    ///
    /// Generous on purpose either way: perspective stretches one half of a row more than the
    /// other, and it is the sign flip that carries the meaning, not the magnitude.
    var maxShapeSlopeSpread: Double = 0.5

    /// How far a detected row may sit from a zone's centre and still be taken as that bin's.
    ///
    /// This is the whole identity mechanism, and it replaces every code that came before it.
    /// The camera does not move and neither do the bins, so *where* a row appears already says
    /// which bin opened; nothing has to be encoded in the marker at all.
    var maxBindingDistance: CGFloat = 0.35

    static let standard = BinMarkerDashConfig()
}
