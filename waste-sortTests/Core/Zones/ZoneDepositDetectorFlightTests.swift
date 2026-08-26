import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

/// The blur-lost-flight cases: an item the model sees held, then never again.
/// These pin the three ways a deposit can be credited without a single tracked
/// frame inside a zone — swept crossings, launch projections, and the open-lid
/// witness that drawer bins make load-bearing.
@Suite("ZoneDepositDetector blur-lost flights")
struct ZoneDepositDetectorFlightTests {
    /// A drawer mouth: small quad, nowhere near the default tiled zones.
    private let mouthZone = DropZone(
        name: "Residual mouth",
        binID: BinGuide.residual.id,
        corners: DropZone.rect(CGRect(x: 0.35, y: 0.05, width: 0.30, height: 0.30))
    )

    private func track(at point: CGPoint, id: Int = 1) -> TrackedDetection {
        TrackedDetection(
            id: id,
            classKey: "tissue",
            className: "tissue",
            conf: 0.6,
            displayXywhn: CGRect(x: point.x - 0.05, y: point.y - 0.05, width: 0.1, height: 0.1),
            misses: 0,
            rawClassKey: "",
            rawConf: 0,
            confirmedBinID: nil
        )
    }

    private final class Clock {
        let detector = ZoneDepositDetector()
        private(set) var now: CFAbsoluteTime = 1_000
        private let zones: [DropZone]
        private let frame: CFAbsoluteTime = 1.0 / 30.0

        init(zones: [DropZone], binState: BinOpenStateProviding? = nil) {
            self.zones = zones
            if let binState { detector.binOpenState = binState }
        }

        @discardableResult
        func tick(_ tracks: [TrackedDetection]) -> ZoneFrameResult {
            now += frame
            return detector.update(tracks: tracks, zones: zones, timestamp: now)
        }

        @discardableResult
        func tick(_ tracks: [TrackedDetection], times: Int) -> ZoneFrameResult {
            var last = ZoneFrameResult()
            for _ in 0..<times { last = tick(tracks) }
            return last
        }
    }

    /// Empty frames covering the whole reacquisition window, accumulating everything the
    /// window emitted — deposits and drops land on the tick the object is reaped, not the
    /// final one.
    private func waitOut(_ c: Clock) -> (deposits: [ZoneDeposit], drops: [DepositDrop]) {
        var deposits: [ZoneDeposit] = []
        var drops: [DepositDrop] = []
        for _ in 0..<Int((c.detector.reacquireGrace + 0.5) * 30) {
            let result = c.tick([])
            deposits += result.deposits
            drops += result.drops
        }
        return (deposits, drops)
    }

    @Test("a drop into the one open drawer is credited even with no tracked flight")
    func openDrawerWitnessesTheDrop() {
        let lids = StubBinState(open: [])
        let c = Clock(zones: [mouthZone], binState: lids)
        // Held below the mouth, jitters — the model never sees the drop itself. The
        // drawer is pulled open mid-hold: the gesture that says this item is going in.
        c.tick([track(at: CGPoint(x: 0.48, y: 0.55))])
        c.tick([track(at: CGPoint(x: 0.48, y: 0.552))])
        lids.openBins = [BinGuide.residual.id]
        c.tick([track(at: CGPoint(x: 0.48, y: 0.548))])
        c.tick([track(at: CGPoint(x: 0.48, y: 0.551))])
        let result = waitOut(c)
        #expect(result.deposits.count == 1)
        #expect(result.deposits.first?.zoneBinID == BinGuide.residual.id)
        #expect(result.deposits.first?.viaTrajectory == true)
    }

    @Test("a vanish far from the one open drawer is still not a deposit")
    func distantVanishIsNotRescuedByOpenLid() {
        let lids = StubBinState(open: [])
        let c = Clock(zones: [mouthZone], binState: lids)
        c.tick([track(at: CGPoint(x: 0.5, y: 0.95))], times: 3)
        lids.openBins = [BinGuide.residual.id]
        c.tick([track(at: CGPoint(x: 0.5, y: 0.95))], times: 3)
        let result = waitOut(c)
        #expect(result.deposits.isEmpty)
        #expect(result.drops.first?.reason == .outsideZones)
    }

    @Test("two open drawers name no bin, so nothing is credited")
    func ambiguousOpenLidsRefuseCredit() {
        let organic = DropZone(
            name: "Organic mouth",
            binID: BinGuide.organic.id,
            corners: DropZone.rect(CGRect(x: 0.0, y: 0.05, width: 0.25, height: 0.30))
        )
        let lids = StubBinState(open: [])
        let c = Clock(zones: [organic, mouthZone], binState: lids)
        c.tick([track(at: CGPoint(x: 0.48, y: 0.55))], times: 2)
        lids.openBins = [BinGuide.organic.id, BinGuide.residual.id]
        c.tick([track(at: CGPoint(x: 0.48, y: 0.55))], times: 3)
        let result = waitOut(c)
        #expect(result.deposits.isEmpty)
    }

    @Test("a fast item whose center jumps clean over the mouth still counts")
    func sweptCrossingCatchesTheJump() {
        let lids = StubBinState(open: [BinGuide.residual.id])
        let c = Clock(zones: [mouthZone], binState: lids)
        // Below the mouth, then beyond it — never inside on either endpoint.
        c.tick([track(at: CGPoint(x: 0.5, y: 0.5))])
        c.tick([track(at: CGPoint(x: 0.5, y: 0.02))])
        let result = waitOut(c)
        #expect(result.deposits.count == 1)
        #expect(result.deposits.first?.zoneBinID == BinGuide.residual.id)
    }

    @Test("a launch toward the mouth stretches the projection past the hand-off point")
    func launchFramesStretchTheReach() {
        let lids = StubBinState(open: [BinGuide.residual.id])
        let c = Clock(zones: [mouthZone], binState: lids)
        // Carried slowly upward, then the release burst — then blur.
        c.tick([track(at: CGPoint(x: 0.5, y: 0.62))])
        c.tick([track(at: CGPoint(x: 0.5, y: 0.60))])
        c.tick([track(at: CGPoint(x: 0.5, y: 0.58))])
        c.tick([track(at: CGPoint(x: 0.5, y: 0.52))])
        let result = waitOut(c)
        #expect(result.deposits.count == 1)
        #expect(result.deposits.first?.zoneBinID == BinGuide.residual.id)
    }

    @Test("a closed drawer still refuses everything the new evidence paths find")
    func closedDrawerRefusesAllPaths() {
        let c = Clock(zones: [mouthZone], binState: StubBinState(open: []))
        // Swept crossing over the mouth with a launch — every kinematic path fires.
        c.tick([track(at: CGPoint(x: 0.5, y: 0.5))])
        c.tick([track(at: CGPoint(x: 0.5, y: 0.02))])
        let result = waitOut(c)
        #expect(result.deposits.isEmpty)
        #expect(result.drops.first?.reason == .binReadShut)
        #expect(result.drops.first?.targetBinID == BinGuide.residual.id)
    }
}

/// Lid stub, local to this file's suites.
private nonisolated final class StubBinState: BinOpenStateProviding {
    var openBins: Set<String>

    init(open: Set<String> = []) {
        openBins = open
    }

    func isOpen(binID: String) -> Bool { openBins.contains(binID) }
}
