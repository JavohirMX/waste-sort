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

@Suite("Bin marker dash rows")
struct BinMarkerDashScannerTests {
    @Test("A printed row is found and counted", arguments: [5, 8, 12, 14])
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
    @Test("Four dashes is below the floor and five is above it")
    func fiveDashesIsTheFloor() {
        let scanner = BinMarkerDashScanner()
        #expect(scanner.scan(canvasWithRow(dashes: 4, dash: 6, thickness: 20)).isEmpty)
        #expect(scanner.scan(canvasWithRow(dashes: 5, dash: 6, thickness: 20)).count == 1)
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
        canvas.fill(x: 60 - 3, y: 40 - dash, width: 16, height: 12 * dash * 2, gray: 240)
        for index in 0..<12 {
            canvas.fill(x: 60, y: 40 + index * dash * 2, width: 10, height: dash, gray: 25)
        }
        let found = BinMarkerDashScanner().scan(canvas.image)
        #expect(found.count == 1)
        #expect(found.first?.orientation == .vertical)
    }

    /// Repetition is the design: an arm over the middle leaves two shorter rows, and the
    /// longer one still answers.
    @Test("An arm across the middle leaves a readable row")
    func occludedMiddle() {
        var canvas = BinMarkerCanvas(width: 520, height: 160, background: 150, includeChroma: false)
        let dash = 6
        canvas.fill(x: 40 - dash, y: 57, width: 14 * dash * 2 + dash, height: 16, gray: 240)
        for index in 0..<14 {
            canvas.fill(x: 40 + index * dash * 2, y: 60, width: dash, height: 10, gray: 25)
        }
        // A dark sleeve over the middle third.
        canvas.fill(x: 40 + 5 * dash * 2, y: 0, width: dash * 2 * 4, height: 160, gray: 40)
        let found = BinMarkerDashScanner().scan(canvas.image)
        #expect(found.contains { $0.dashes >= 5 })
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

    @Test("A row too thin for three scan lines is discarded")
    func tooThin() {
        let scanner = BinMarkerDashScanner()
        #expect(scanner.scan(canvasWithRow(dashes: 10, dash: 6, thickness: 6)).isEmpty)
        #expect(scanner.scan(canvasWithRow(dashes: 10, dash: 6, thickness: 16)).count == 1)
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
        let frame = detector.update(zones: list, style: .dashes, timestamp: 100)
        #expect(frame.statuses[list[1].id]?.state == .open)
        #expect(frame.statuses[list[0].id]?.state == .closed)
    }

    @Test("A row far from every bin opens none of them")
    func distantRowIsIgnored() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: CGPoint(x: 0.5, y: 0.95))], timestamp: 100)
        let frame = detector.update(zones: list, style: .dashes, timestamp: 100)
        #expect(frame.openZoneIDs.isEmpty)
    }

    @Test("More dashes clear of the edge reads as more certain")
    func dashCountDrivesConfidence() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: list[0].centroid, dashes: 4)], timestamp: 100)
        let sparse = detector.update(zones: list, style: .dashes, timestamp: 100)
        detector.ingest(rows: [row(at: list[0].centroid, dashes: 14)], timestamp: 101)
        let full = detector.update(zones: list, style: .dashes, timestamp: 101)
        let low = sparse.statuses[list[0].id]?.confidence ?? 0
        let high = full.statuses[list[0].id]?.confidence ?? 0
        #expect(low < high)
    }

    @Test("Openness coasts through a dropout, then gives up")
    func coasting() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: list[0].centroid)], timestamp: 100)
        _ = detector.update(zones: list, style: .dashes, timestamp: 100)
        let coasting = detector.update(zones: list, style: .dashes, timestamp: 101)
        #expect(coasting.statuses[list[0].id]?.state == .open)
        #expect(coasting.statuses[list[0].id]?.isCoasting == true)
        let lapsed = detector.update(zones: list, style: .dashes, timestamp: 103)
        #expect(lapsed.statuses[list[0].id]?.state == .closed)
    }

    @Test("Dash state feeds the deposit gate unchanged")
    func feedsTheGate() {
        let detector = BinMarkerStateDetector()
        let list = zones(2)
        detector.ingest(rows: [row(at: list[0].centroid)], timestamp: 100)
        let frame = detector.update(zones: list, style: .dashes, timestamp: 100)
        let gate = FrameBinOpenState(markerFrame: frame, zones: list)
        #expect(gate.isOpen(binID: list[0].binID))
        #expect(!gate.isOpen(binID: list[1].binID))
    }
}
