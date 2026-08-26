import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

private func canvasWithRow(
    dashes: Int,
    dash: Int,
    thickness: Int = 10,
    origin: (x: Int, y: Int) = (x: 40, y: 60),
    width: Int = 420,
    height: Int = 160,
    background: UInt8 = 150
) -> BinMarkerImage {
    var canvas = BinMarkerCanvas(width: width, height: height, background: background,
                                 includeChroma: false)
    // The printed sticker: white ground, then the dashes on it.
    let span = dashes * dash * 2 - dash
    canvas.fill(x: origin.x - dash, y: origin.y - 3,
                width: span + dash * 2, height: thickness + 6, gray: 240)
    for index in 0..<dashes {
        canvas.fill(x: origin.x + index * dash * 2, y: origin.y,
                    width: dash, height: thickness, gray: 25)
    }
    return canvas.image
}

/// The same row with every dash bent into a V: the offset climbs a sample per scan line to the
/// midline and falls a sample per line after it, which is the slope of 1 the printed sheet
/// carries at a shear of half the row's height.
private func canvasWithChevronRow(
    dashes: Int,
    dash: Int,
    thickness: Int = 12,
    origin: (x: Int, y: Int) = (x: 40, y: 60),
    straight: Bool = false
) -> BinMarkerImage {
    var canvas = BinMarkerCanvas(width: 420, height: 160, background: 150, includeChroma: false)
    let half = thickness / 2
    let span = dashes * dash * 2 - dash
    canvas.fill(x: origin.x - dash - half, y: origin.y - 3,
                width: span + dash * 2 + thickness, height: thickness + 6, gray: 240)
    for row in 0..<thickness {
        // Straight rows are drawn with the *same* lean throughout, so what separates them from
        // a chevron is only the reversal — which is exactly the thing being tested.
        let offset = straight ? row : (row < half ? row : thickness - 1 - row)
        for index in 0..<dashes {
            canvas.fill(x: origin.x + index * dash * 2 + offset, y: origin.y + row,
                        width: dash, height: 1, gray: 25)
        }
    }
    return canvas.image
}

@Suite("Bin marker dash rows")
struct BinMarkerDashScannerTests {
    @Test("A printed row is found and counted", arguments: [6, 8, 12, 14])
    func rowIsCounted(dashes: Int) throws {
        let scanner = BinMarkerDashScanner()
        let found = try #require(scanner.scan(canvasWithRow(dashes: dashes, dash: 6, thickness: 20)).first)
        #expect(found.dashes == dashes)
        #expect(found.orientation == .horizontal)
        #expect(abs(found.pitchSamples - 6) < 1.5)
    }

    /// Eight runs is where the site's own frames stop producing false rows — 39 at five, 7 at
    /// six, 3 at seven, none at eight — and a clean row of N dashes reads as 2N−1 runs, so the
    /// floor lands on five dashes. To trigger sooner, print them smaller, not fewer.
    @Test("The floor is where the profile puts it", arguments: BinMarkerDashProfile.allCases)
    func profileSetsTheFloor(profile: BinMarkerDashProfile) {
        var config = BinMarkerDashConfig.standard
        config.profile = profile
        let scanner = BinMarkerDashScanner(config: config)
        let needed = profile.dashesNeeded
        #expect(scanner.scan(canvasWithRow(dashes: needed - 1, dash: 6, thickness: 20)).isEmpty)
        #expect(scanner.scan(canvasWithRow(dashes: needed, dash: 6, thickness: 20)).count == 1)
    }

    /// A shorter sticker is paid for with one more dash, so the two always move together —
    /// which is why height and run count are one setting rather than two knobs.
    @Test("A thinner profile costs a dash and a finer row stride")
    func thinnerCostsADash() {
        #expect(BinMarkerDashProfile.tall.dashesNeeded == 5)
        #expect(BinMarkerDashProfile.thin.dashesNeeded == 6)
        #expect(BinMarkerDashProfile.veryThin.dashesNeeded == 7)
        #expect(BinMarkerDashProfile.tall.rowStride > BinMarkerDashProfile.thin.rowStride)
        #expect(BinMarkerDashProfile.thin.rowStride > BinMarkerDashProfile.veryThin.rowStride)
    }

    /// The shortest setting was called hairline before it was called very thin, and a device
    /// left on it must come back on it rather than quietly stepping up to thin.
    @MainActor
    @Test("A device already on the shortest profile stays on it")
    func storedProfileSurvivesTheRename() {
        #expect(BinMarkerDashProfile(rawValue: "hairline") == .veryThin)
        let defaults = UserDefaults(suiteName: "test.binmarker.profile.\(UUID())")!
        defaults.set("hairline", forKey: "binMarker.dashProfile")
        #expect(BinMarkerStore(defaults: defaults).dashProfile == .veryThin)
    }

    /// Nothing here divides one width by another, which is why dashes survive at a size the
    /// bar rhythm could not be read at.
    @Test("Dashes hold up down to two samples", arguments: [2, 3, 4, 8])
    func smallDashes(dash: Int) {
        let scanner = BinMarkerDashScanner()
        let found = scanner.scan(canvasWithRow(dashes: 10, dash: dash, thickness: max(16, dash * 4)))
        #expect(found.count == 1)
        #expect(found.first?.dashes == 10)
    }

    @Test("A row standing on end is found by the column pass")
    func verticalRow() {
        var canvas = BinMarkerCanvas(width: 200, height: 400, background: 150, includeChroma: false)
        let dash = 6
        // Wide on purpose. Columns are scanned at a coarse stride because a flat row gets
        // nothing from them, so a row mounted the other way round has to be broad enough for
        // several columns to cross — the asymmetry is the price of a thin flat row.
        canvas.fill(x: 47, y: 40 - dash, width: 46, height: 12 * dash * 2, gray: 240)
        for index in 0..<12 {
            canvas.fill(x: 50, y: 40 + index * dash * 2, width: 40, height: dash, gray: 25)
        }
        let found = BinMarkerDashScanner().scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.orientation == .vertical)
    }

    /// Repetition is the design: an arm over the middle leaves two shorter rows, and the
    /// longer one still answers.
    @Test("An arm across the middle leaves a readable row")
    func occludedMiddle() {
        var canvas = BinMarkerCanvas(width: 700, height: 160, background: 150, includeChroma: false)
        let dash = 6
        canvas.fill(x: 40 - dash, y: 57, width: 20 * dash * 2 + dash, height: 16, gray: 240)
        for index in 0..<20 {
            canvas.fill(x: 40 + index * dash * 2, y: 60, width: dash, height: 10, gray: 25)
        }
        // A dark sleeve over the middle third.
        canvas.fill(x: 40 + 5 * dash * 2, y: 0, width: dash * 2 * 4, height: 160, gray: 40)
        let found = BinMarkerDashScanner().scan(canvas.image)
        #expect(found.contains { $0.dashes >= 6 })
    }

    @Test("A blank scene finds nothing")
    func blankScene() {
        let canvas = BinMarkerCanvas(width: 420, height: 160, background: 150, includeChroma: false)
        #expect(BinMarkerDashScanner().scan(canvas.image).isEmpty)
    }

    /// A row of unequal runs is something else. Agreement between the runs is the entire
    /// signature — the room is full of alternating dark and light, and empty of nine of them
    /// at one pitch.
    @Test("Runs that disagree with each other are not a row")
    func unevenRunsRejected() {
        var canvas = BinMarkerCanvas(width: 420, height: 160, background: 150, includeChroma: false)
        canvas.fill(x: 30, y: 57, width: 340, height: 16, gray: 240)
        var x = 40
        for width in [4, 14, 5, 20, 6, 17, 4, 22, 5] {
            canvas.fill(x: x, y: 60, width: width, height: 10, gray: 25)
            x += width + 6
        }
        #expect(BinMarkerDashScanner().scan(canvas.image).isEmpty)
    }

    /// Three scan lines have to cross the row, so its floor in samples is three times the
    /// profile's row stride — which is the whole reason the profile exists.
    @Test("The height floor follows the profile", arguments: BinMarkerDashProfile.allCases)
    func heightFloorFollowsProfile(profile: BinMarkerDashProfile) {
        var config = BinMarkerDashConfig.standard
        config.profile = profile
        let scanner = BinMarkerDashScanner(config: config)
        let floor = profile.rowStride * 3
        let dashes = profile.dashesNeeded + 4
        #expect(scanner.scan(canvasWithRow(dashes: dashes, dash: 6, thickness: floor - profile.rowStride)).isEmpty)
        #expect(scanner.scan(canvasWithRow(dashes: dashes, dash: 6, thickness: floor + 2)).count == 1)
    }
}

@Suite("Bin marker chevrons")
struct BinMarkerChevronTests {
    private var scanner: BinMarkerDashScanner {
        var config = BinMarkerDashConfig.standard
        config.shape = .chevron
        return BinMarkerDashScanner(config: config)
    }

    /// The bend is the whole point: it buys a lower run threshold than a plain row can safely
    /// carry, because the shape is doing the discriminating instead of the sheer length.
    @Test("A bent row opens on four dashes", arguments: [4, 5, 6, 9])
    func chevronRowIsRead(dashes: Int) throws {
        let found = try #require(scanner.scan(canvasWithChevronRow(dashes: dashes, dash: 6)).first)
        #expect(found.dashes == dashes)
        #expect(found.orientation == .horizontal)
    }

    /// A counter lip, a wood seam, a sleeve: in perspective they all lean, and at this run
    /// threshold a plain row of four dashes is well inside what the room produces by accident.
    /// What none of them can do is reverse that lean at a midline.
    @Test("A leaning row is not a bent one")
    func straightRowsAreRejected() {
        #expect(scanner.scan(canvasWithChevronRow(dashes: 4, dash: 6, straight: true)).isEmpty)
        #expect(scanner.scan(canvasWithRow(dashes: 4, dash: 6, thickness: 12)).isEmpty)
    }

    /// The scan lines across the top and bottom of a print cut half-covered ink, and often
    /// report an offset from somewhere else entirely. Splitting the lines down the middle and
    /// fitting each half by least squares put those outliers inside a half, and the error that
    /// caused grew with the slope — so the check rejected exactly the steepest, least
    /// mistakable chevrons. Both halves of the fix are load-bearing.
    @Test("A row with a ragged edge line is still read")
    func outlierLinesSurvive() {
        let bent = canvasWithChevronRow(dashes: 9, dash: 6, thickness: 12)
        var gray = bent.gray
        // The row's top scan line replaced by alternation that starts at the page edge rather
        // than at the first dash — which is what a half-covered row of ink actually produces.
        for x in 0..<bent.width where x % 12 < 6 { gray[60 * bent.width + x] = 25 }
        let ragged = BinMarkerImage(width: bent.width, height: bent.height, gray: gray)
        #expect(!scanner.scan(ragged).isEmpty)
    }
}

@Suite("Bin marker dash openness")
struct BinMarkerDashStateTests {
    private func zones(_ count: Int) -> [DropZone] {
        (0..<count).map { index in
            DropZone(
                name: "Zone \(index)",
                binID: BinGuide.all[min(index, BinGuide.all.count - 1)].id,
                corners: DropZone.rect(
                    CGRect(x: 0.05 + Double(index) * 0.45, y: 0.4, width: 0.3, height: 0.3)
                )
            )
        }
    }

    private func row(at center: CGPoint, dashes: Int = 10) -> BinMarkerDashRow {
        BinMarkerDashRow(
            orientation: .horizontal,
            bounds: CGRect(x: center.x - 0.1, y: center.y - 0.01, width: 0.2, height: 0.02),
            dashes: dashes,
            pitchSamples: 5,
            lineCount: 6,
            timestamp: 0
        )
    }

    /// The whole identity mechanism: a row is credited to the bin it is nearest, because the
    /// camera and the bins do not move.
    @Test("A row opens the bin it appears nearest")
    func nearestZoneWins() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: list[1].centroid)], timestamp: 100)
        let frame = detector.update(zones: list, timestamp: 100)
        #expect(frame.statuses[list[1].id]?.state == .open)
        #expect(frame.statuses[list[0].id]?.state == .closed)
    }

    @Test("A row far from every bin opens none of them")
    func distantRowIsIgnored() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: CGPoint(x: 0.5, y: 0.95))], timestamp: 100)
        let frame = detector.update(zones: list, timestamp: 100)
        #expect(frame.openZoneIDs.isEmpty)
    }

    @Test("More dashes clear of the edge reads as more certain")
    func dashCountDrivesConfidence() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: list[0].centroid, dashes: 6)], timestamp: 100)
        let sparse = detector.update(zones: list, timestamp: 100)
        detector.ingest(rows: [row(at: list[0].centroid, dashes: 14)], timestamp: 101)
        let full = detector.update(zones: list, timestamp: 101)
        let low = sparse.statuses[list[0].id]?.confidence ?? 0
        let high = full.statuses[list[0].id]?.confidence ?? 0
        #expect(low < high)
    }

    @Test("Openness coasts through a dropout, then gives up")
    func coasting() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: list[0].centroid)], timestamp: 100)
        _ = detector.update(zones: list, timestamp: 100)
        let coasting = detector.update(zones: list, timestamp: 101)
        #expect(coasting.statuses[list[0].id]?.state == .open)
        #expect(coasting.statuses[list[0].id]?.isCoasting == true)
        let lapsed = detector.update(zones: list, timestamp: 103)
        #expect(lapsed.statuses[list[0].id]?.state == .closed)
    }

    @Test("Dash state feeds the deposit gate unchanged")
    func feedsTheGate() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: list[0].centroid)], timestamp: 100)
        let frame = detector.update(zones: list, timestamp: 100)
        let gate = FrameBinOpenState(markerFrame: frame, zones: list)
        #expect(gate.isOpen(binID: list[0].binID))
        #expect(!gate.isOpen(binID: list[1].binID))
    }
}
