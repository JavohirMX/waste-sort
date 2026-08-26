import CoreGraphics
import Foundation

/// One frame reduced to what marker detection needs: 8-bit luma, and interleaved Rec. 601
/// chroma when the camera gave us any.
///
/// Both planes are on the same grid, and that grid is the *chroma* resolution rather than
/// the full frame's. Chroma arrives at half size from the camera anyway, so matching luma
/// down to it costs a quarter of the work and loses nothing: the bars are centimetres wide.
nonisolated struct BinMarkerImage: Equatable, Sendable {
    let width: Int
    let height: Int
    /// `width * height` samples.
    let gray: [UInt8]
    /// `width * height * 2` samples, Cb then Cr per pixel. Nil for a monochrome source, which
    /// restricts detection to `BinMarkerStyle.mono`.
    let chroma: [UInt8]?

    var hasChroma: Bool { chroma != nil }

    init(width: Int, height: Int, gray: [UInt8], chroma: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.gray = gray
        self.chroma = chroma
    }

    var isUsable: Bool {
        width > 0 && height > 0
            && gray.count >= width * height
            && (chroma == nil || chroma!.count >= width * height * 2)
    }
}

/// Which way the bars run across the image.
///
/// Only the two axis-aligned cases exist, because only they can be found by walking straight
/// lines through the buffer. A strip mounted at an angle is not detected at all, which is
/// the honest failure: the printable sheet says to mount it level.
nonisolated enum BinMarkerOrientation: String, Equatable, Sendable {
    /// Bars stacked left-to-right, so a row of pixels crosses all of them.
    case horizontal
    /// Bars stacked top-to-bottom, crossed by a column.
    case vertical
}

/// Detector knobs. Every tolerance here is generous on purpose — the strip is a printed thing
/// under unknown light, and a tight threshold just means a bin that silently never opens.
nonisolated struct BinMarkerConfig: Equatable, Sendable {
    var style: BinMarkerStyle = .color

    /// Examine every Nth row and every Nth column.
    ///
    /// One, because the short side of the strip is the scarce dimension in practice. A camera
    /// looking down at a row of bins sees their walls as narrow rims, and a marker has to live
    /// on that rim. Three scan lines must cross the strip before it is believed, so the stride
    /// sets the minimum thickness directly: at two it takes six samples, at one it takes three.
    ///
    /// Measured on a 960x540 working grid, one strip present: 1.5 ms per frame for the colour
    /// style against 0.7 ms at stride two, and 6 ms against 3 ms for mono, whose sliding local
    /// threshold is the expensive part. Halving what has to be printed is worth that.
    var scanStride: Int = 1

    /// A one-unit bar narrower than this is below the resolution where widths mean anything.
    var minUnitSamples: Double = 2.0
    /// ...and wider than this is something large in the room, not a strip on a bin.
    var maxUnitSamples: Double = 60.0

    /// Bar width, in units, above which a bar reads as the wide kind. Sits midway between the
    /// printed 1 and 2 so it takes a gross misread to cross it.
    var wideThreshold: Double = 1.5
    /// Bars outside this range are not one of ours at any rounding.
    var minBarUnits: Double = 0.55
    var maxBarUnits: Double = 2.7
    /// Widest gap over narrowest gap. The gaps are the ruler, so a set that disagrees with
    /// itself means the ruler is wrong and the whole window has to go.
    var maxGapSpread: Double = 2.2

    /// Runs shorter than this are folded into their neighbour before anything is read.
    /// The edge between ink and paper never lands on a pixel boundary, and chroma arrives
    /// at half resolution, so every real bar comes fenced by a sample or two of neither.
    var minRunSamples: Int = 2

    /// Scan lines that must agree before a strip is reported. Rejects the single-row
    /// coincidence, which is the only kind of noise that reliably survives everything else.
    var minLines: Int = 3

    /// Chroma magnitude, measured from neutral, that separates the strip's background from
    /// its bars. One threshold, not a band with a no-man's-land in the middle.
    ///
    /// That detail is load-bearing and was learned the hard way. A gap of "neither" between
    /// the two classes costs nothing on a synthetic frame with razor edges, and everything on
    /// a real one: blur turns every bar edge into a ramp, the ramp spends several samples
    /// inside the band, and those samples break the alternation the scan is looking for. With
    /// a single threshold the boundary lands on one sample, and since it moves outward on one
    /// side of a bar exactly as far as it moves inward on the other, the width ratios the
    /// rhythm is read from come out unchanged.
    ///
    /// No luma test goes with it: a gap only has to be *not ink*, and leaving brightness out
    /// is what lets the same code read a white-gapped strip and a black-gapped one.
    /// Raised from 16 after the colour style outlined half a bin room. Sixteen is 14% of a
    /// saturated ink's chroma — a threshold that admits almost anything that is not literally
    /// grey. A printed ink under working light sits far above 40%.
    var inkChromaThreshold: Double = 45
    /// How far a sample's hue may sit from an ink's before it stops being that ink, in degrees
    /// around the chroma plane.
    ///
    /// An **angle**, not a distance to the ink's centroid, and that is the whole point.
    /// Everything that weakens a printed colour — blur mixing in the paper, a faded print,
    /// haze, a camera that under-saturates — slides the sample along the ray toward neutral.
    /// Its distance from the fully saturated centroid grows, while its direction does not
    /// move at all. Measuring the distance meant a bar dissolving into its own background was
    /// read as some unknown colour and thrown away; measuring the angle means it is read as a
    /// paler version of itself, which is what it is.
    ///
    /// The three inks sit at least 92 degrees apart, so this stays unambiguous with room to
    /// spare, and it is what keeps a saturated colour that is none of ours out.
    ///
    /// Narrowed from 35 after the field reported the colour style outlining everything in
    /// sight. Three cones of ±35° claim 58% of every hue there is — most coloured rubbish
    /// lands inside one. At ±20° they claim a third, and on a synthetic cluttered scene that
    /// took false detections from five per twelve frames to zero without costing a single
    /// real read, blurred or crisp.
    ///
    /// It does mean an uncalibrated print whose hue is off by more than 20° goes unread, so
    /// the colour style now genuinely depends on calibrating against the real print.
    var maxInkHueDegrees: Double = 20

    /// Local light-to-dark spread a mono scan line needs before its samples mean anything.
    /// Flat wall is not a strip with unlucky thresholds; it is flat wall.
    var minMonoContrast: Int = 40
    /// Half-width of the sliding window the mono threshold is taken from, in samples.
    ///
    /// This sets the **largest** strip that can be read, which is not obvious and is worth
    /// stating plainly: the threshold at each sample is the midpoint of the window around it,
    /// so a bar wider than the window has a middle whose neighbourhood is all ink. The
    /// midpoint there sits inside the ink, the centre of the bar reads as paper, and the bar
    /// splits in two. The widest printed bar is two units, so the readable ceiling is roughly
    /// this radius in samples per unit.
    ///
    /// Raised from 24 after a lone 12 mm strip went unread at close range while the same strip
    /// read perfectly from further away — a 28-sample unit, a 57-sample wide bar, against a
    /// 48-sample window. Measured against the printed sheet and fifteen frames of the empty
    /// room:
    ///
    ///     radius │ largest readable print │ false strips │ ms a pass
    ///         24 │                  10 mm │            3 │       59
    ///         32 │                  12 mm │            3 │       59
    ///         40 │                  15 mm │            1 │       60
    ///         56 │                  15 mm │            0 │       60
    ///
    /// Wider is better on both counts and costs nothing — the sliding extreme is linear in the
    /// line length whatever this is — because a wider window is likelier to hold both ink and
    /// paper, which is the whole job. Forty is where it first covers every size on the sheet;
    /// past that the only difference is one false strip in fifteen frames, which is noise, and
    /// a window is still supposed to be local enough that a lighting gradient across the room
    /// is not what gets measured.
    var monoWindowRadius: Int = 40

    /// Accept a color strip that shows at least `minDegradedBars` bars but no readable
    /// rhythm, naming the bin from its ink alone. This is the whole point of printing in
    /// color: past the distance where widths survive, the hue still does.
    var allowDegradedColor: Bool = true
    var minDegradedBars: Int = 3

    static let standard = BinMarkerConfig()
}

/// One strip found in one frame.
nonisolated struct BinMarkerDetection: Equatable, Sendable {
    /// Rhythm that matched, or nil when the strip was only resolved well enough to read ink.
    var patternID: Int?
    /// Ink that matched, or nil under `BinMarkerStyle.mono`, which prints no ink.
    var inkID: String?
    var orientation: BinMarkerOrientation
    /// Normalized 0…1, top-left origin, unflipped — the same space as `DropZone.corners` and
    /// `TrackedDetection.displayXywhn`, so zone containment needs no conversion.
    var bounds: CGRect
    /// How many scan lines agreed on this strip.
    var lineCount: Int
    /// Measured unit width in working-image samples. Small values mean the strip is at the
    /// edge of readable and wants a bigger print or more resolution.
    var unitSamples: Double
    /// Mean chroma of the strip's bars, for the calibration read-out. Neutral under `.mono`.
    var chroma: CGPoint
    var timestamp: CFAbsoluteTime

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// Whether identity came from ink alone because the rhythm could not be read.
    var isDegraded: Bool { patternID == nil }
}

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
///     setting  height  stride  dashes  travel at 8 mm   cost   false rows
///     tall     15.0mm       4       5           72 mm   10 ms           0
///     thin      7.5mm       2       6           88 mm   17 ms           0
///
/// **Tall is better on every axis a bin cares about** — it opens a dash sooner and costs
/// two-fifths of the frame time — so the only reason to choose thin is a rim that cannot give
/// up 15 mm. Prefer tall wherever the sticker fits.
///
/// A third setting, hairline, is gone. It scanned every line for a 3.8 mm sticker and was
/// therefore both the slowest (31 ms) and the least sensitive (7 dashes): strictly worse than
/// thin for any print over about 7.5 mm, which is every print on the sheet. It was answering a
/// question the printed sheets stopped asking. A device left on it comes back on thin, which
/// is what the raw value failing to decode already does.
nonisolated enum BinMarkerDashProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case tall
    case thin

    var id: String { rawValue }

    var rowStride: Int {
        switch self {
        case .tall: return 4
        case .thin: return 2
        }
    }

    /// Raised in step with the stride, because the extra scan lines have to be paid for.
    var minRuns: Int {
        switch self {
        case .tall: return 8
        case .thin: return 10
        }
    }

    /// Printed dashes that must clear the counter edge. A clean row of N dashes reads as
    /// 2N−1 runs, so this is `ceil((minRuns + 1) / 2)`.
    var dashesNeeded: Int { (minRuns + 2) / 2 }

    var displayName: String {
        switch self {
        case .tall: return "Tall"
        case .thin: return "Thin"
        }
    }

    var detail: String {
        switch self {
        case .tall:
            return "Wants about 15 mm of printed height. Opens on 5 dashes and is the lighter "
                + "of the two on frame rate — use it wherever the rim allows."
        case .thin:
            return "About 7.5 mm, for a rim that cannot give up more. Costs a dash to open, "
                + "and about half again the time a frame."
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

/// Openness of one zone, as the marker layer sees it.
nonisolated struct BinMarkerOpenness: Equatable, Sendable {
    var state: BinOpennessState = .unknown
    var confidence: Double = 0
    /// The strip bound to this zone.
    var slot: Int?
    /// True when the strip was named by its ink alone. Worth surfacing: it means the print is
    /// at the edge of its range, and the mono style would already have lost the bin.
    var isDegraded: Bool = false
    /// True while openness is being held over a gap in sightings rather than seen outright.
    var isCoasting: Bool = false
    var lastSeenAt: CFAbsoluteTime = 0
}

/// One tick of marker-driven bin state.
nonisolated struct BinMarkerStatusFrame: Equatable, Sendable {
    var statuses: [UUID: BinMarkerOpenness] = [:]
    var detections: [BinMarkerDetection] = []
    /// Populated instead of `detections` under the dash style.
    var rows: [BinMarkerDashRow] = []
    var timestamp: CFAbsoluteTime = 0
    /// Diagnostics from the most recent scan, for the debug overlay. Nil when marker
    /// detection is off.
    var stats: BinMarkerFrameStats?

    var closedZoneIDs: Set<UUID> {
        Set(statuses.compactMap { $0.value.state == .closed ? $0.key : nil })
    }

    var openZoneIDs: Set<UUID> {
        Set(statuses.compactMap { $0.value.state == .open ? $0.key : nil })
    }
}

/// State-machine settings, kept apart from the detector's own knobs because these are the
/// ones an operator actually turns on site.
nonisolated struct BinMarkerStateConfig: Equatable, Sendable {
    /// How long a strip may go unseen before its bin is called shut.
    ///
    /// This is the load-bearing number of the whole feature, and it is a trade, not a
    /// tuning: a hidden strip is the only evidence of a closed bin, so anything that hides
    /// one — an arm reaching in, someone standing in front of the bins, a blown highlight —
    /// reads as closed too. Longer is more forgiving of that and slower to notice a real lid
    /// coming down.
    var staleTimeout: CFAbsoluteTime = 2.0

    /// How far a dash row may sit from a zone's centre and still be taken as that bin's.
    var maxBindingDistance: CGFloat = 0.35

    static let staleTimeoutRange = 0.2...5.0
    static let staleTimeoutStep = 0.1

    static let standard = BinMarkerStateConfig()
}

/// One detection pass, for the debug overlay and on-site aiming.
nonisolated struct BinMarkerFrameStats: Equatable, Sendable {
    var sourceWidth: Int = 0
    var sourceHeight: Int = 0
    /// Scan lines examined this pass.
    var linesScanned: Int = 0
    /// Alternating runs that looked strip-shaped before identity was checked.
    var candidateCount: Int = 0
    var acceptedCount: Int = 0
    /// Widest unit measured this pass, in working-image samples. The single most useful
    /// number when aiming a camera: if it hovers near `minUnitSamples`, the print is too
    /// small for the distance.
    var largestUnitSamples: Double?
    var detectionMilliseconds: Double = 0
    /// Set when the frame carried no chroma but the color style was asked for.
    var missingChroma: Bool = false
}
