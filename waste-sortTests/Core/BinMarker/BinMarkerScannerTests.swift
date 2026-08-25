import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

private func scanner(
    _ style: BinMarkerStyle,
    _ mutate: (inout BinMarkerConfig) -> Void = { _ in }
) -> BinMarkerScanner {
    var config = BinMarkerConfig.standard
    config.style = style
    mutate(&config)
    return BinMarkerScanner(config: config)
}

@Suite("Bin marker patterns")
struct BinMarkerPatternTests {
    @Test("Every rhythm reads the same backwards")
    func patternsArePalindromes() {
        for pattern in BinMarkerPattern.all {
            #expect(pattern.barUnits == pattern.barUnits.reversed())
            #expect(pattern.barUnits.count == BinMarkerPattern.barCount)
        }
    }

    @Test("Rhythms differ only by how many bars are wide")
    func patternsDifferByWideCount() {
        #expect(BinMarkerPattern.all.map(\.id) == [1, 2, 3])
    }

    /// Pinned against `BinMarkers/markers.typ`, which draws these same three rhythms onto the
    /// printable sheets. The two are not compiled together, so this is what stops them
    /// drifting apart — and a sheet that disagrees with the scanner is the worst bug this
    /// feature could have, because it presents as a detection fault for ever.
    ///
    /// If this fails, the rhythms changed: update the sheet and reprint, or put them back.
    @Test("The printed rhythms are the rhythms the scanner accepts")
    func patternsMatchThePrintedSheet() {
        #expect(BinMarkerPattern.all.map(\.barUnits) == [
            [1, 1, 2, 1, 1],
            [2, 1, 1, 1, 2],
            [2, 1, 2, 1, 2]
        ])
        #expect(BinMarkerInk.all.map(\.id) == ["yellow", "magenta", "cyan"])
        // The sheet prints one unit of white between bars and one at each end.
        #expect(BinMarkerPattern.gapUnits == 1)
    }

    @Test("A rhythm we never printed does not resolve")
    func unknownRhythmIsRejected() {
        #expect(BinMarkerPattern.matching([1, 2, 2, 1, 1]) == nil)
        #expect(BinMarkerPattern.matching([1, 1, 1, 1, 1]) == nil)
        #expect(BinMarkerPattern.matching([1, 1, 2, 1, 1])?.id == 1)
        #expect(BinMarkerPattern.matching([2, 1, 2, 1, 2])?.id == 3)
    }

    /// Classification is by hue, so what has to be far apart is the angle, not the distance.
    @Test("No sample can sit near two inks at once")
    func paletteIsWellSeparated() {
        func angle(_ ink: BinMarkerInk) -> Double {
            atan2(ink.cr - 128, ink.cb - 128) * 180 / .pi
        }
        var closest = Double.greatestFiniteMagnitude
        for (index, ink) in BinMarkerInk.all.enumerated() {
            for other in BinMarkerInk.all.dropFirst(index + 1) {
                var separation = abs(angle(ink) - angle(other)).truncatingRemainder(dividingBy: 360)
                if separation > 180 { separation = 360 - separation }
                closest = min(closest, separation)
            }
        }
        #expect(closest > 2 * BinMarkerConfig.standard.maxInkHueDegrees)
    }
}

@Suite("Bin marker scanner, colour")
struct BinMarkerColorScannerTests {
    @Test("A horizontal strip reads its rhythm and its ink")
    func horizontalStrip() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.single.barUnits,
                            unit: 6, origin: (x: 40, y: 90), thickness: 24)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == 1)
        #expect(found.first?.inkID == "magenta")
        #expect(found.first?.orientation == .horizontal)
        #expect(found.first?.isDegraded == false)
    }

    @Test("A vertical strip is found by the column pass")
    func verticalStrip() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.cyan, barUnits: BinMarkerPattern.double.barUnits,
                            unit: 6, origin: (x: 120, y: 40), thickness: 24,
                            orientation: .vertical)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.orientation == .vertical)
        #expect(found.first?.patternID == 2)
    }

    @Test("All three rhythms read back as themselves", arguments: BinMarkerPattern.all)
    func everyRhythmRoundTrips(pattern: BinMarkerPattern) {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.yellow, barUnits: pattern.barUnits,
                            unit: 6, origin: (x: 30, y: 90), thickness: 24)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == pattern.id)
    }

    @Test("Five bars in the wrong proportions are not a strip read badly")
    func unprintedRhythmIsRejected() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.magenta, barUnits: [1, 2, 2, 1, 1],
                            unit: 6, origin: (x: 40, y: 90), thickness: 24)
        let found = scanner(.color) { $0.allowDegradedColor = false }.scan(canvas.image)
        #expect(found.isEmpty)
    }

    @Test("An unmatched hue never names a bin")
    func offPaletteInkIsRejected() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        let ink = BinMarkerTestInk.offPalette
        canvas.drawStrip(barUnits: BinMarkerPattern.single.barUnits, unit: 6,
                         origin: (x: 40, y: 90), thickness: 24, orientation: .horizontal,
                         gray: BinMarkerTestInk.luma(of: ink),
                         cb: UInt8(ink.cb), cr: UInt8(ink.cr))
        #expect(scanner(.color).scan(canvas.image).isEmpty)
    }

    @Test("Shadow across the strip changes nothing")
    func shadowIsIgnored() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.triple.barUnits,
                            unit: 6, origin: (x: 40, y: 90), thickness: 24)
        canvas.shade(x: 0, y: 0, width: 160, height: 240, scale: 0.35)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == 3)
    }

    @Test("The gaps are the ruler, so scale does not matter", arguments: [3, 6, 14])
    func scaleInvariance(unit: Int) {
        var canvas = BinMarkerCanvas(width: 400, height: 300)
        canvas.drawInkStrip(.cyan, barUnits: BinMarkerPattern.double.barUnits,
                            unit: unit, origin: (x: 20, y: 100), thickness: max(8, unit * 3))
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == 2)
        #expect(abs((found.first?.unitSamples ?? 0) - Double(unit)) <= 1.5)
    }

    @Test("Two inks in one frame stay two strips")
    func twoInks() {
        var canvas = BinMarkerCanvas(width: 400, height: 300)
        canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.single.barUnits,
                            unit: 6, origin: (x: 30, y: 60), thickness: 24)
        canvas.drawInkStrip(.cyan, barUnits: BinMarkerPattern.triple.barUnits,
                            unit: 6, origin: (x: 30, y: 180), thickness: 24)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 2)
        #expect(Set(found.compactMap(\.inkID)) == ["magenta", "cyan"])
    }

    /// Two bins side by side carry identical strips and land on the same scan lines. The
    /// background between them classifies as gap exactly like the millimetres between bars do.
    @Test("Two identical strips on the same rows are not welded together")
    func identicalStripsStaySeparate() {
        var canvas = BinMarkerCanvas(width: 400, height: 300)
        canvas.drawInkStrip(.yellow, barUnits: BinMarkerPattern.single.barUnits,
                            unit: 6, origin: (x: 20, y: 120), thickness: 24)
        canvas.drawInkStrip(.yellow, barUnits: BinMarkerPattern.single.barUnits,
                            unit: 6, origin: (x: 260, y: 120), thickness: 24)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 2)
        for detection in found {
            #expect(detection.patternID == 1)
            #expect(detection.bounds.width < 0.35)
        }
    }

    /// The short side is the scarce one: a top-down camera sees a bin wall as a narrow rim,
    /// and that is where the marker has to go. Three samples is the floor, and it is the floor
    /// for a structural reason — three scan lines have to cross the strip.
    @Test("A strip three samples thin is still read", arguments: [3, 4, 6])
    func thinStripsAreRead(thickness: Int) {
        var canvas = BinMarkerCanvas(width: 420, height: 200)
        canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.single.barUnits,
                            unit: 8, origin: (x: 40, y: 90), thickness: thickness)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == 1)
        #expect((found.first?.lineCount ?? 0) >= BinMarkerConfig.standard.minLines)
    }

    @Test("Two samples is below the floor and is discarded")
    func tooThinIsDiscarded() {
        var canvas = BinMarkerCanvas(width: 420, height: 200)
        canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.single.barUnits,
                            unit: 8, origin: (x: 40, y: 90), thickness: 2)
        #expect(scanner(.color).scan(canvas.image).isEmpty)
    }

    /// Length and thickness are independent — nothing ties a bar's height to its width — so a
    /// marker for a rim can be as long and thin as the rim is.
    @Test("A strip twenty times longer than it is thick reads fine")
    func extremeAspectRatioIsFine() {
        var canvas = BinMarkerCanvas(width: 620, height: 200)
        canvas.drawInkStrip(.cyan, barUnits: BinMarkerPattern.triple.barUnits,
                            unit: 10, origin: (x: 40, y: 90), thickness: 5)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == 3)
    }

    @Test("An empty frame finds nothing")
    func blankFrame() {
        let canvas = BinMarkerCanvas(width: 320, height: 240)
        #expect(scanner(.color).scan(canvas.image).isEmpty)
        #expect(scanner(.mono).scan(canvas.image).isEmpty)
    }

    /// Silence would present as three permanently shut bins, so the pass has to say why it
    /// found nothing.
    @Test("A monochrome source under the colour style records that it had no chroma")
    func missingChromaIsReported() {
        var canvas = BinMarkerCanvas(width: 320, height: 240, includeChroma: false)
        canvas.drawMonoStrip(barUnits: BinMarkerPattern.single.barUnits,
                             unit: 6, origin: (x: 40, y: 90), thickness: 24)
        let scan = scanner(.color)
        #expect(scan.scan(canvas.image).isEmpty)
        #expect(scan.lastFrameStats.missingChroma)
    }

    @Test("A strip smeared down to three bars still names its bin by ink")
    func degradedStripIsAccepted() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.cyan, barUnits: [1, 1, 1], unit: 6,
                            origin: (x: 40, y: 90), thickness: 24)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == nil)
        #expect(found.first?.isDegraded == true)
        #expect(found.first?.inkID == "cyan")
    }

    @Test("The degraded tier can be switched off")
    func degradedTierIsOptional() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.cyan, barUnits: [1, 1, 1], unit: 6,
                            origin: (x: 40, y: 90), thickness: 24)
        #expect(scanner(.color) { $0.allowDegradedColor = false }.scan(canvas.image).isEmpty)
    }

    @Test("Two bars is a pair of blobs, never a marker")
    func twoBarsIsNeverEnough() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.magenta, barUnits: [1, 1], unit: 6,
                            origin: (x: 40, y: 90), thickness: 24)
        #expect(scanner(.color).scan(canvas.image).isEmpty)
    }

    /// The bug this guards: identity used to be nearest-centroid by Euclidean distance, so a
    /// bar at half strength sat 55 units from its own ink against a 48-unit tolerance and was
    /// discarded as an unknown colour. Fading moves a sample along the ray toward neutral and
    /// leaves its direction alone, which is why the classifier reads the angle.
    @Test("A washed-out print is still its own colour", arguments: [0.15, 0.3, 0.45])
    func fadedInkIsStillRecognised(amount: Double) {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(BinMarkerTestInk.faded(.magenta, by: amount),
                            barUnits: BinMarkerPattern.single.barUnits,
                            unit: 6, origin: (x: 40, y: 90), thickness: 24)
        let found = scanner(.color).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.inkID == "magenta")
        #expect(found.first?.patternID == 1)
    }

    /// Blur is what turns a full read into a degraded one, and the degraded tier is the whole
    /// argument for printing in colour. Measured rather than assumed: at this unit size the
    /// rhythm is gone and the ink is all that is left.
    /// Past the point where the bars survive at all, the ink still names the bin. That
    /// fallback is the whole argument for printing in colour rather than black.
    @Test("A strip blurred past its rhythm keeps its bin")
    func blurFallsBackToInk() {
        var canvas = BinMarkerCanvas(width: 420, height: 200)
        canvas.drawInkStrip(.cyan, barUnits: BinMarkerPattern.triple.barUnits,
                            unit: 6, origin: (x: 30, y: 70), thickness: 24)
        let soft = BinMarkerTestBlur.apply(canvas.image, radius: 4)
        let found = scanner(.color).scan(soft)
        #expect(found.contains { $0.isDegraded && $0.slot(style: .color)?.index == 2 })
    }

    /// Raising the chroma floor to 45 bought this as well as the false positives it was aimed
    /// at: a blur that dilutes a gap no longer pushes it over the line into ink, so the bars
    /// stay separate and the rhythm survives where it used to collapse.
    @Test("Moderate blur no longer costs the rhythm")
    func moderateBlurKeepsRhythm() throws {
        var canvas = BinMarkerCanvas(width: 420, height: 200)
        canvas.drawInkStrip(.cyan, barUnits: BinMarkerPattern.triple.barUnits,
                            unit: 6, origin: (x: 30, y: 70), thickness: 24)
        let soft = BinMarkerTestBlur.apply(canvas.image, radius: 2)
        let found = try #require(scanner(.color).scan(soft).first)
        #expect(found.patternID == 3)
        #expect(found.isDegraded == false)
    }

    /// Print the unit large enough and the rhythm survives blur too. Measured, not assumed:
    /// a radius-1 box applied in both axes spreads over five samples, so at unit 14 that is
    /// about a third of a unit and the widths still separate. Around unit 10 and below the
    /// same blur takes the rhythm and leaves only the ink — which is the trade the two styles
    /// are really being asked to make.
    @Test("A large enough unit keeps its rhythm through blur")
    func largeUnitKeepsRhythmUnderBlur() {
        var canvas = BinMarkerCanvas(width: 620, height: 200)
        canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.double.barUnits,
                            unit: 14, origin: (x: 30, y: 70), thickness: 24)
        let soft = BinMarkerTestBlur.apply(canvas.image, radius: 1)
        let found = scanner(.color).scan(soft)
        #expect(found.count == 1)
        #expect(found.first?.patternID == 2)
        #expect(found.first?.isDegraded == false)
    }

    @Test("Bounds land where the strip was drawn")
    func boundsAreAccurate() throws {
        var canvas = BinMarkerCanvas(width: 400, height: 200)
        let length = canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.single.barUnits,
                                         unit: 8, origin: (x: 80, y: 60), thickness: 40)
        let found = try #require(scanner(.color).scan(canvas.image).first)
        #expect(abs(found.bounds.minX - 80.0 / 400.0) < 0.02)
        #expect(abs(found.bounds.width - Double(length) / 400.0) < 0.03)
        #expect(abs(found.bounds.minY - 60.0 / 200.0) < 0.04)
    }

    @Test("Stats describe the pass")
    func statsAreReported() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.yellow, barUnits: BinMarkerPattern.double.barUnits,
                            unit: 6, origin: (x: 40, y: 90), thickness: 24)
        let scan = scanner(.color)
        _ = scan.scan(canvas.image)
        let stats = scan.lastFrameStats
        #expect(stats.sourceWidth == 320)
        #expect(stats.sourceHeight == 240)
        #expect(stats.linesScanned == 240 + 320)
        #expect(stats.acceptedCount == 1)
        #expect((stats.largestUnitSamples ?? 0) > 4)
        #expect(!stats.missingChroma)
    }
}

/// The bins are in pull-out drawers, so a marker emerges from under a counter edge and the
/// surface just past it is deep shadow. These are the cases that only exist because of that.
@Suite("Bin marker scanner against a counter edge")
struct BinMarkerEdgeTests {
    /// Under the mono style a shadow *is* a black bar as far as a local threshold is
    /// concerned. Across the printed margin it joins the strip as a sixth bar, and six bars
    /// is not a rhythm we print — so the bin went unread at the very moment it opened.
    @Test("A shadow beyond the printed margin is not a sixth bar",
          arguments: [BinMarkerStyle.color, .mono])
    func shadowBesideTheStripIsTrimmed(style: BinMarkerStyle) {
        var canvas = BinMarkerCanvas(width: 460, height: 160)
        let origin = (x: 60, y: 60)
        let length: Int
        if style == .color {
            length = canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.single.barUnits,
                                         unit: 8, origin: origin, thickness: 12)
        } else {
            length = canvas.drawMonoStrip(barUnits: BinMarkerPattern.single.barUnits,
                                          unit: 8, origin: origin, thickness: 12)
        }
        // One unit of printed white past the last bar, then the counter's shadow.
        let edge = origin.x + length + 8
        canvas.fill(x: edge, y: 0, width: 460 - edge, height: 160, gray: 30)

        let found = scanner(style).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == 1)
    }

    /// Half out is enough for colour and not for mono, because the ink keeps naming the bin
    /// after the rhythm has been cut in half. Worth pinning: it is the difference the two
    /// styles actually make in this deployment.
    @Test("Half emerged, colour names the bin and mono does not",
          arguments: [BinMarkerStyle.color, .mono])
    func halfEmerged(style: BinMarkerStyle) {
        var canvas = BinMarkerCanvas(width: 460, height: 160)
        let origin = (x: 60, y: 60)
        let length: Int
        if style == .color {
            length = canvas.drawInkStrip(.cyan, barUnits: BinMarkerPattern.triple.barUnits,
                                         unit: 8, origin: origin, thickness: 12)
        } else {
            length = canvas.drawMonoStrip(barUnits: BinMarkerPattern.triple.barUnits,
                                          unit: 8, origin: origin, thickness: 12)
        }
        let edge = origin.x + length / 2
        canvas.fill(x: edge, y: 0, width: 460 - edge, height: 160, gray: 30)

        let named = scanner(style).scan(canvas.image)
            .contains { $0.slot(style: style)?.index == 2 }
        #expect(named == (style == .color))
    }
}

@Suite("Bin marker scanner, black and white")
struct BinMarkerMonoScannerTests {
    @Test("A black-on-white strip reads its rhythm", arguments: BinMarkerPattern.all)
    func rhythmRoundTrips(pattern: BinMarkerPattern) {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawMonoStrip(barUnits: pattern.barUnits, unit: 6,
                             origin: (x: 40, y: 90), thickness: 24)
        let found = scanner(.mono).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == pattern.id)
        #expect(found.first?.inkID == nil)
    }

    /// Three black bars name no bin, and guessing which one is worse than missing it.
    @Test("Mono refuses the degraded tier")
    func degradedTierIsUnavailable() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawMonoStrip(barUnits: [1, 1, 1], unit: 6,
                             origin: (x: 40, y: 90), thickness: 24)
        #expect(scanner(.mono).scan(canvas.image).isEmpty)
    }

    /// One lamp over one end of the bins would put a whole strip on one side of any single
    /// threshold, which is why the mono classifier reads a sliding local window instead.
    @Test("Mono survives a lighting gradient across the frame")
    func gradientIsAbsorbed() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawMonoStrip(barUnits: BinMarkerPattern.triple.barUnits, unit: 6,
                             origin: (x: 40, y: 90), thickness: 24)
        canvas.shade(x: 0, y: 0, width: 160, height: 240, scale: 0.45)
        let found = scanner(.mono).scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.patternID == 3)
    }

    @Test("Flat surfaces have nothing to threshold against")
    func flatSurfaceIsIgnored() {
        var canvas = BinMarkerCanvas(width: 320, height: 240, background: 180)
        canvas.fill(x: 40, y: 90, width: 120, height: 24, gray: 186)
        #expect(scanner(.mono).scan(canvas.image).isEmpty)
    }
}
