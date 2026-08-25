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

    /// Examine every Nth row and every Nth column. Two is already fine: a strip is many
    /// samples tall, so it is crossed by plenty of lines either way.
    var scanStride: Int = 2

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
    var inkChromaThreshold: Double = 16
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
    var maxInkHueDegrees: Double = 35

    /// Local light-to-dark spread a mono scan line needs before its samples mean anything.
    /// Flat wall is not a strip with unlucky thresholds; it is flat wall.
    var minMonoContrast: Int = 40
    /// Half-width of the sliding window the mono threshold is taken from, in samples. Wide
    /// enough to span a bar and its neighbours, narrow enough that a lighting gradient across
    /// the frame never becomes the thing being measured.
    var monoWindowRadius: Int = 24

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
