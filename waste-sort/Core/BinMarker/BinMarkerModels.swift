import CoreGraphics
import Foundation

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
