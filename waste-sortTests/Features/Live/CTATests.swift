import CoreGraphics
import Testing
@testable import waste_sort

struct CTACueMapperTests {
    private let imageSize = CGSize(width: 1920, height: 1080)
    private let viewSize = CGSize(width: 1024, height: 768)

    @Test func skipsUnknownClass() {
        let tracks = [
            track(id: 1, classKey: "organic", width: 0.3, height: 0.3),
            track(id: 2, classKey: "mystery", width: 0.3, height: 0.3)
        ]
        let cues = map(tracks)
        #expect(cues.map(\.trackID) == [1])
        #expect(cues.first?.binID == "organic")
    }

    @Test func skipsCoastingTracks() {
        let tracks = [
            track(id: 1, classKey: "organic", width: 0.3, height: 0.3),
            TrackedDetection(
                id: 2,
                classKey: "residual",
                className: "residual",
                conf: 0.9,
                displayXywhn: CGRect(x: 0.5, y: 0.2, width: 0.3, height: 0.3),
                misses: 1
            )
        ]
        let cues = map(tracks)
        #expect(cues.map(\.trackID) == [1])
    }

    @Test func oneCuePerTrack() {
        let tracks = [
            track(id: 1, classKey: "organic", x: 0.1, y: 0.2, width: 0.2, height: 0.2),
            track(id: 2, classKey: "organic", x: 0.5, y: 0.4, width: 0.15, height: 0.18),
            track(id: 3, classKey: "residual", x: 0.7, y: 0.3, width: 0.2, height: 0.25)
        ]
        let cues = map(tracks)
        #expect(cues.map(\.trackID) == [1, 2, 3])
        #expect(cues.map(\.binID) == ["organic", "organic", "residual"])
    }

    @Test func mapsCleanInorganicToBinID() {
        let cues = map([track(id: 4, classKey: "inorganic", width: 0.25, height: 0.25)])
        #expect(cues.first?.binID == "clean_inorganic")
    }

    @Test func dirtyRecyclableLightsResidualAndRecyclable() {
        let cues = map([
            track(id: 7, classKey: BinGuide.dirtyRecyclable.id, width: 0.3, height: 0.3),
        ])
        #expect(Set(cues.map(\.binID)) == [BinGuide.residual.id, BinGuide.cleanInorganic.id])
        #expect(Set(cues.map(\.trackID)) == [7])
        #expect(CTACueMapper.activeBinIDs(from: cues) == [BinGuide.residual.id, BinGuide.cleanInorganic.id])
    }

    @Test func mappedRectsAreLargeEnoughToDraw() {
        let cues = map([track(id: 1, classKey: "residual", width: 0.3, height: 0.25)])
        #expect(cues.count == 1)
        #expect(cues[0].displayRect.width > 1)
        #expect(cues[0].displayRect.height > 1)
    }

    @Test func skipsTinyBoxes() {
        let cues = map([track(id: 1, classKey: "organic", width: 0.0001, height: 0.0001)])
        #expect(cues.isEmpty)
    }

    private func map(_ tracks: [TrackedDetection]) -> [CTACue] {
        CTACueMapper.cues(
            from: tracks,
            imageSize: imageSize,
            viewSize: viewSize,
            rotation: .zero,
            mirror: false
        )
    }
}

struct CTAArrowPathTests {
    private let start = CGPoint(x: 200, y: 400)
    private let end = CGPoint(x: 80, y: 90)

    @Test func quadraticEndsMatchStartAndEnd() {
        let control = CTAArrowPath.controlPoint(from: start, to: end)
        let atStart = CTAArrowPath.quadraticPoint(t: 0, start: start, control: control, end: end)
        let atEnd = CTAArrowPath.quadraticPoint(t: 1, start: start, control: control, end: end)
        #expect(abs(atStart.x - start.x) < 1e-9)
        #expect(abs(atStart.y - start.y) < 1e-9)
        #expect(abs(atEnd.x - end.x) < 1e-9)
        #expect(abs(atEnd.y - end.y) < 1e-9)
    }

    @Test func controlPointBendsTowardDestination() {
        let control = CTAArrowPath.controlPoint(from: start, to: end)
        #expect(control.x < start.x)
        #expect(control.x > end.x)
        #expect(control.y < start.y)
        #expect(control.y > end.y)
    }

    @Test func samplesUsesCountFromPathLength() {
        let length = CTAArrowPath.approximateLength(from: start, to: end)
        let samples = CTAArrowPath.samples(from: start, to: end, phase: 0)
        #expect(samples.count == CTAArrowPath.chevronCount(forPathLength: length))
    }

    @Test func longerPathUsesMoreChevrons() {
        let nearby = CTAArrowPath.samples(
            from: CGPoint(x: 90, y: 160),
            to: CGPoint(x: 80, y: 90),
            phase: 0
        )
        let far = CTAArrowPath.samples(
            from: CGPoint(x: 520, y: 780),
            to: CGPoint(x: 80, y: 90),
            phase: 0
        )
        #expect(nearby.count < far.count)
        #expect(nearby.count >= CTAArrowPath.minCount)
        #expect(far.count <= CTAArrowPath.maxCount)
    }

    @Test func chevronCountClampsToBounds() {
        #expect(CTAArrowPath.chevronCount(forPathLength: 10) == CTAArrowPath.minCount)
        #expect(CTAArrowPath.chevronCount(forPathLength: 4000) == CTAArrowPath.maxCount)
        #expect(CTAArrowPath.chevronCount(forPathLength: 0) == CTAArrowPath.minCount)
    }

    @Test func sizeIncreasesTowardTheBin() {
        let samples = CTAArrowPath.samples(from: start, to: end, phase: 0)
        #expect(samples.first!.size < samples.last!.size)
        #expect(samples.first!.opacity < samples.last!.opacity)
    }

    @Test func wrap01FoldsOverflowAndNegatives() {
        #expect(abs(CTAArrowPath.wrap01(1.25) - 0.25) < 1e-9)
        #expect(abs(CTAArrowPath.wrap01(-0.25) - 0.75) < 1e-9)
        #expect(abs(CTAArrowPath.wrap01(0) - 0) < 1e-9)
    }

    @Test func convertShiftsRectIntoCameraSpace() {
        let rect = CGRect(x: 40, y: 80, width: 100, height: 56)
        let converted = CTALayout.convert(rect, from: CGPoint(x: 0, y: -47))
        #expect(abs(converted.minX - 40) < 1e-9)
        #expect(abs(converted.minY - 127) < 1e-9)
        #expect(abs(converted.width - 100) < 1e-9)
        #expect(abs(converted.height - 56) < 1e-9)
    }
}

private func track(
    id: Int,
    classKey: String,
    x: CGFloat = 0.2,
    y: CGFloat = 0.2,
    width: CGFloat,
    height: CGFloat
) -> TrackedDetection {
    TrackedDetection(
        id: id,
        classKey: classKey,
        className: classKey,
        conf: 0.9,
        displayXywhn: CGRect(x: x, y: y, width: width, height: height)
    )
}
