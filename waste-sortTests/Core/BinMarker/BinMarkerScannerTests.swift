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

    @Test("A rhythm we never printed does not resolve")
    func unknownRhythmIsRejected() {
        #expect(BinMarkerPattern.matching([1, 2, 2, 1, 1]) == nil)
        #expect(BinMarkerPattern.matching([1, 1, 1, 1, 1]) == nil)
        #expect(BinMarkerPattern.matching([1, 1, 2, 1, 1])?.id == 1)
        #expect(BinMarkerPattern.matching([2, 1, 2, 1, 2])?.id == 3)
    }

    @Test("No sample can sit near two inks at once")
    func paletteIsWellSeparated() {
        var closest = Double.greatestFiniteMagnitude
        for (index, ink) in BinMarkerInk.all.enumerated() {
            for other in BinMarkerInk.all.dropFirst(index + 1) {
                closest = min(closest, ink.distance(cb: other.cb, cr: other.cr))
            }
        }
        #expect(closest > 2 * BinMarkerConfig.standard.maxInkDistance)
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

    @Test("A strip too thin to cross several scan lines is noise")
    func thinStripIsDiscarded() {
        var canvas = BinMarkerCanvas(width: 320, height: 240)
        canvas.drawInkStrip(.magenta, barUnits: BinMarkerPattern.single.barUnits,
                            unit: 6, origin: (x: 40, y: 90), thickness: 2)
        #expect(scanner(.color).scan(canvas.image).isEmpty)
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
        #expect(stats.linesScanned == 160 + 120)
        #expect(stats.acceptedCount == 1)
        #expect((stats.largestUnitSamples ?? 0) > 4)
        #expect(!stats.missingChroma)
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
