import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

/// Lid state under test control: everything reads closed unless it is listed as open.
private nonisolated final class StubBinState: BinOpenStateProviding {
    var openBins: Set<String>

    init(open: Set<String> = []) {
        openBins = open
    }

    func isOpen(binID: String) -> Bool { openBins.contains(binID) }
}

@Suite("ZoneDepositDetector")
struct ZoneDepositDetectorTests {
    private let organicZone = DropZone(
        name: "Organic bin",
        binID: BinGuide.organic.id,
        corners: DropZone.rect(CGRect(x: 0.0, y: 0.0, width: 0.4, height: 1.0))
    )

    private let residualZone = DropZone(
        name: "Residual bin",
        binID: BinGuide.residual.id,
        corners: DropZone.rect(CGRect(x: 0.6, y: 0.0, width: 0.4, height: 1.0))
    )

    /// A small quad in the corner, for the trajectory cases: the two zones above span the
    /// whole frame height, so there is nowhere in them that counts as "clear of the bins".
    private let mouthZone = DropZone(
        name: "Organic mouth",
        binID: BinGuide.organic.id,
        corners: DropZone.rect(CGRect(x: 0.05, y: 0.60, width: 0.30, height: 0.30))
    )

    private var zones: [DropZone] { [organicZone, residualZone] }

    private func track(
        id: Int = 1,
        classKey: String = "organic",
        at point: CGPoint,
        misses: Int = 0,
        rawClassKey: String = "",
        rawConf: Float = 0
    ) -> TrackedDetection {
        TrackedDetection(
            id: id,
            classKey: classKey,
            className: classKey,
            conf: 0.9,
            displayXywhn: CGRect(x: point.x - 0.05, y: point.y - 0.05, width: 0.1, height: 0.1),
            misses: misses,
            rawClassKey: rawClassKey,
            rawConf: rawConf
        )
    }

    private func track(
        id: Int = 1,
        classKey: String = "organic",
        centerX: CGFloat,
        centerY: CGFloat = 0.5,
        misses: Int = 0,
        rawClassKey: String = "",
        rawConf: Float = 0
    ) -> TrackedDetection {
        track(
            id: id,
            classKey: classKey,
            at: CGPoint(x: centerX, y: centerY),
            misses: misses,
            rawClassKey: rawClassKey,
            rawConf: rawConf
        )
    }

    /// Drives the detector frame by frame at a fixed 30fps so the time-based reacquisition
    /// window is exercised deterministically.
    private final class Clock {
        let detector = ZoneDepositDetector()
        private(set) var now: CFAbsoluteTime = 1_000
        private let zones: [DropZone]
        private let frame: CFAbsoluteTime = 1.0 / 30.0

        init(
            zones: [DropZone],
            dwell: Int = 3,
            grace: CFAbsoluteTime = 1.4,
            binState: BinOpenStateProviding? = nil
        ) {
            self.zones = zones
            detector.requiredDwellFrames = dwell
            detector.reacquireGrace = grace
            if let binState {
                detector.binOpenState = binState
            }
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

        /// Runs empty frames until the reacquisition window has certainly elapsed.
        @discardableResult
        func waitOutGrace() -> [ZoneDeposit] {
            var collected: [ZoneDeposit] = []
            for _ in 0..<Int((detector.reacquireGrace + 0.5) * 30) {
                collected.append(contentsOf: tick([]).deposits)
            }
            return collected
        }

        /// Empty frames covering roughly `seconds`, collecting anything that fires.
        @discardableResult
        func idle(seconds: CFAbsoluteTime) -> [ZoneDeposit] {
            var collected: [ZoneDeposit] = []
            for _ in 0..<max(1, Int(seconds * 30)) {
                collected.append(contentsOf: tick([]).deposits)
            }
            return collected
        }
    }

    private func clock(
        dwell: Int = 3,
        grace: CFAbsoluteTime = 1.4,
        binState: BinOpenStateProviding? = nil
    ) -> Clock {
        Clock(zones: zones, dwell: dwell, grace: grace, binState: binState)
    }

    private func mouthClock(
        grace: CFAbsoluteTime = 1.4,
        binState: BinOpenStateProviding? = nil
    ) -> Clock {
        Clock(zones: [mouthZone], dwell: 3, grace: grace, binState: binState)
    }

    // MARK: - The basic throw

    @Test("entering a zone, dwelling, then staying gone counts once")
    func straightforwardThrow() {
        let c = clock()
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 3)
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneID == organicZone.id)
        #expect(deposits.first?.isCorrect == true)
        #expect(deposits.first?.trackSegments == 1)
        #expect(deposits.first?.viaTrajectory == false)
        #expect(deposits.first?.binWasOpen == true)
    }

    @Test("the deposit is withheld until the reacquire window has passed")
    func depositIsDeferred() {
        let c = clock(grace: 1.0)
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 3)
        // Half a second after it vanished nothing has been decided yet.
        #expect(c.idle(seconds: 0.5).isEmpty)
        #expect(!c.idle(seconds: 0.8).isEmpty)
    }

    @Test("a mismatched category is recorded as incorrect")
    func mismatchIsIncorrect() {
        let c = clock()
        c.tick([track(centerX: 0.5)])
        c.tick([track(classKey: "organic", centerX: 0.8)], times: 3)
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneBinID == BinGuide.residual.id)
        #expect(deposits.first?.isCorrect == false)
    }

    @Test("two items released together produce two deposits")
    func twoAtOnce() {
        let c = clock()
        let both = [
            track(id: 1, classKey: "organic", centerX: 0.2),
            track(id: 2, classKey: "residual", centerX: 0.8),
        ]
        c.tick([track(id: 1, centerX: 0.45), track(id: 2, centerX: 0.55)])
        c.tick(both, times: 3)
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 2)
        #expect(deposits.filter { $0.isCorrect }.count == 2)
    }

    @Test("no zones means no deposits and no retained state")
    func noZones() {
        let detector = ZoneDepositDetector()
        _ = detector.update(tracks: [track(centerX: 0.2)], zones: [], timestamp: 1)
        #expect(detector.update(tracks: [], zones: [], timestamp: 2).deposits.isEmpty)
    }

    // MARK: - The bin has to be open

    @Test("an item lost over a closed bin is not a throw")
    func closedBinIsNotAThrow() {
        let c = clock(binState: StubBinState(open: []))
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 4)
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("the lid only has to read open at some point while the item is gone")
    func lidMayLagTheThrow() {
        // The lid signal is noisy and can lag the release by a few frames, so the whole
        // settling window is inspected rather than the single frame the item vanished on.
        let lids = StubBinState(open: [])
        let c = clock(grace: 1.0, binState: lids)
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 4)
        c.idle(seconds: 0.3)
        lids.openBins = [BinGuide.organic.id]
        c.tick([])
        lids.openBins = []
        #expect(c.waitOutGrace().count == 1)
    }

    @Test("only the target bin's lid matters")
    func anotherBinBeingOpenDoesNotCount() {
        let c = clock(binState: StubBinState(open: [BinGuide.residual.id]))
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 4)
        #expect(c.waitOutGrace().isEmpty)
    }

    // MARK: - Dropouts must not read as throws

    @Test("a momentary dropout inside the zone is not a throw")
    func blinkIsNotAThrow() {
        let c = clock()
        c.tick([track(id: 1, centerX: 0.5)])
        c.tick([track(id: 1, centerX: 0.2)], times: 3)
        // Gone for half a second, then the tracker issues a fresh id at the same spot.
        c.idle(seconds: 0.5)
        c.tick([track(id: 2, centerX: 0.2)], times: 3)
        // Only one item ever existed, so only one deposit — after it is really gone.
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.trackSegments == 2)
    }

    @Test("a dropout that comes back and is carried away is never counted")
    func blinkThenCarriedOut() {
        let c = clock()
        c.tick([track(id: 1, centerX: 0.5)])
        c.tick([track(id: 1, centerX: 0.2)], times: 5)
        c.idle(seconds: 0.4)
        // Reappears in the zone, then is carried back out and set down in the gap, moving
        // down it rather than at either bin.
        c.tick([track(id: 2, centerX: 0.2)])
        c.tick([track(id: 2, centerX: 0.5, centerY: 0.5)])
        c.tick([track(id: 2, centerX: 0.5, centerY: 0.75)])
        c.tick([track(id: 2, centerX: 0.5, centerY: 0.9)], times: 2)
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("a relabelled item is the same item, not a new one")
    func classChangeIsNotANewItem() {
        let c = clock()
        c.tick([track(id: 1, classKey: "organic", centerX: 0.5)])
        c.tick([track(id: 1, classKey: "organic", centerX: 0.2)], times: 3)
        c.idle(seconds: 0.3)
        // When association fails, the detector stitches by proximity — a new id with a
        // different label is still the same cup.
        c.tick([track(id: 2, classKey: "residual", centerX: 0.2)], times: 2)
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.classesSeen == 2)
        // Organic had more confidence behind it across the object's life.
        #expect(deposits.first?.classKey == "organic")
    }

    /// Low-IoU relabel fallback: the tracker cannot associate the new label, so it coasts
    /// the old track for `maxMisses` frames *while* the new one is already live. Both are
    /// in the array at once. Treating the frozen box as a sighting used to strand the old
    /// object — armed, never adopted, firing a throw that never happened — and disqualify
    /// the new one for having been born inside the zone.
    @Test("a relabel with overlapping coasting frames is still one item")
    func classChangeWithOverlappingCoastFrames() {
        let c = clock(dwell: 2)
        c.tick([track(id: 1, classKey: "organic", centerX: 0.5)])
        c.tick([track(id: 1, classKey: "organic", centerX: 0.2)], times: 3)

        // Frame 1 of the relabel: old track coasts alone, new track not yet confirmed.
        c.tick([track(id: 1, classKey: "organic", centerX: 0.2, misses: 1)])
        // Frames 2-3: both emitted at once — frozen organic beside live residual.
        for miss in 2...3 {
            c.tick([
                track(id: 1, classKey: "organic", centerX: 0.2, misses: miss),
                track(id: 2, classKey: "residual", centerX: 0.2),
            ])
        }
        // The old track is finally dropped and only the new one continues.
        c.tick([track(id: 2, classKey: "residual", centerX: 0.2)], times: 3)

        // One object throughout: nothing fired while the item was still on camera.
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.trackSegments == 2)
        #expect(deposits.first?.classesSeen == 2)
    }

    @Test("a frozen box alone does not keep an object present")
    func coastingDoesNotHoldTheObjectOpen() {
        let c = clock(dwell: 2)
        c.tick([track(id: 1, centerX: 0.5)])
        c.tick([track(id: 1, centerX: 0.2)], times: 2)
        // The model has lost it; only the frozen box remains. The reacquisition window
        // should already be running, not waiting for the tracker to give up.
        let coasting = c.tick([track(id: 1, centerX: 0.2, misses: 1)])
        #expect(coasting.occupiedZoneIDs.isEmpty)
        #expect(coasting.settlingZoneIDs == [organicZone.id])
    }

    @Test("a reappearance beyond the window is a different object")
    func reappearanceAfterWindowIsNew() {
        let c = clock(grace: 0.5)
        c.tick([track(id: 1, centerX: 0.5)])
        c.tick([track(id: 1, centerX: 0.2)], times: 3)
        // Long enough that the first object has already been judged and counted.
        #expect(c.idle(seconds: 1.0).count == 1)
        // This one was never seen outside, so it reads as waste already in the bin.
        c.tick([track(id: 2, centerX: 0.2)], times: 5)
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("a reappearance far away is a different object")
    func reappearanceFarAwayIsNew() {
        let c = clock()
        c.tick([track(id: 1, centerX: 0.5)])
        c.tick([track(id: 1, centerX: 0.05)], times: 3)
        c.tick([])
        // Across the frame in one frame time: not the same thing.
        c.tick([track(id: 2, centerX: 0.95)], times: 5)
        let deposits = c.waitOutGrace()
        // The first object is credited; the second was never seen outside a zone.
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneID == organicZone.id)
    }

    /// With `confirmHits` at 1 the tracker confirms the replacement id on the very frame it
    /// coasts the old one, so the old object has not been marked missing yet. Adoption has
    /// to work off "not claimed this frame", not off the missing flag alone.
    @Test("a relabel confirmed on the same frame is still one item")
    func classChangeConfirmedImmediately() {
        let c = clock(dwell: 2)
        c.tick([track(id: 1, classKey: "organic", centerX: 0.5)])
        c.tick([track(id: 1, classKey: "organic", centerX: 0.2)], times: 2)
        // Same frame: old id frozen, new id already live.
        c.tick([
            track(id: 1, classKey: "organic", centerX: 0.2, misses: 1),
            track(id: 2, classKey: "residual", centerX: 0.2),
        ])
        c.tick([track(id: 2, classKey: "residual", centerX: 0.2)], times: 2)
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.trackSegments == 2)
    }

    /// Track order inside a frame is arbitrary, so a new id arriving before the live id it
    /// sits next to must not be able to steal that object.
    @Test("a new track listed first cannot steal a live object")
    func newTrackDoesNotStealALiveObject() {
        let c = clock(dwell: 2)
        c.tick([track(id: 1, centerX: 0.5)])
        c.tick([track(id: 1, centerX: 0.2)], times: 2)
        // Second item appears right next to the first, and happens to come first in the array.
        c.tick([track(id: 2, centerX: 0.22), track(id: 1, centerX: 0.2)], times: 2)
        // Two objects, and the newcomer was born inside the open bin, so only one is credited.
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.trackSegments == 1)
    }

    @Test("two objects visible at once are never merged")
    func simultaneousObjectsStaySeparate() {
        let c = clock()
        c.tick([track(id: 1, centerX: 0.45), track(id: 2, centerX: 0.5)])
        let result = c.tick([track(id: 1, centerX: 0.2), track(id: 2, centerX: 0.25)], times: 3)
        #expect(result.occupiedZoneIDs == [organicZone.id])
        #expect(c.waitOutGrace().count == 2)
    }

    // MARK: - Bin contents

    @Test("an item that only ever appeared inside an open bin is never counted")
    func materialisedInsideAnOpenBinIsIgnored() {
        let c = clock(binState: StubBinState(open: [BinGuide.organic.id]))
        c.tick([track(centerX: 0.2)], times: 20)
        #expect(c.waitOutGrace().isEmpty)
    }

    /// A shut lid cannot be where the item came from, so something resting on one arrived
    /// from outside by definition and stays throwable.
    @Test("an item that appeared on a closed bin is still throwable")
    func materialisedOnAClosedBinStaysEligible() {
        let lids = StubBinState(open: [])
        let c = clock(binState: lids)
        c.tick([track(centerX: 0.2)], times: 4)
        // Someone opens the bin and in it goes.
        lids.openBins = [BinGuide.organic.id]
        c.tick([track(centerX: 0.2)], times: 2)
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneID == organicZone.id)
    }

    @Test("a tracked item reappearing inside the zone can still be thrown")
    func trackedItemReappearingInZoneStillCounts() {
        let c = clock()
        // Seen outside, then lost before it ever reached the zone.
        c.tick([track(id: 1, centerX: 0.5)], times: 2)
        c.idle(seconds: 0.4)
        // Comes back already inside the zone. Because it is the same tracked object,
        // it keeps the credit it earned outside.
        c.tick([track(id: 2, centerX: 0.2)], times: 3)
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.trackSegments == 2)
    }

    // MARK: - Vanishing on the way in

    @Test("an item lost just short of the bin, still moving into it, counts")
    func vanishingOnApproachCounts() {
        let c = mouthClock()
        c.tick([track(at: CGPoint(x: 0.60, y: 0.35))])
        c.tick([track(at: CGPoint(x: 0.53, y: 0.42))])
        c.tick([track(at: CGPoint(x: 0.46, y: 0.49))])
        // Two centimetres short of the mouth when the hand hides it.
        c.tick([track(at: CGPoint(x: 0.42, y: 0.53))])
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneID == mouthZone.id)
        #expect(deposits.first?.viaTrajectory == true)
        #expect(deposits.first?.dwellFrames == 0)
    }

    @Test("an item lost while moving away from the bin does not count")
    func vanishingWhileLeavingIsNotAThrow() {
        let c = mouthClock()
        c.tick([track(at: CGPoint(x: 0.46, y: 0.49))])
        c.tick([track(at: CGPoint(x: 0.53, y: 0.42))])
        c.tick([track(at: CGPoint(x: 0.60, y: 0.35))])
        c.tick([track(at: CGPoint(x: 0.67, y: 0.28))])
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("an item lost too far out to reach the bin does not count")
    func vanishingOutOfReachIsNotAThrow() {
        let c = mouthClock()
        c.tick([track(at: CGPoint(x: 0.90, y: 0.20))])
        c.tick([track(at: CGPoint(x: 0.83, y: 0.27))])
        c.tick([track(at: CGPoint(x: 0.76, y: 0.34))])
        // Pointed at the bin, but half a frame away from it.
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("an item set down beside the bin and then lost does not count")
    func stationaryLossIsNotAThrow() {
        let c = mouthClock()
        c.tick([track(at: CGPoint(x: 0.42, y: 0.53))], times: 6)
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("a two-frame flicker beside the bin does not count")
    func briefFlickerOnApproachIsNotAThrow() {
        let c = mouthClock()
        c.tick([track(at: CGPoint(x: 0.49, y: 0.46))])
        c.tick([track(at: CGPoint(x: 0.42, y: 0.53))])
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("an approach into a closed bin does not count either")
    func approachIntoAClosedBinIsNotAThrow() {
        let c = mouthClock(binState: StubBinState(open: []))
        c.tick([track(at: CGPoint(x: 0.60, y: 0.35))])
        c.tick([track(at: CGPoint(x: 0.53, y: 0.42))])
        c.tick([track(at: CGPoint(x: 0.46, y: 0.49))])
        c.tick([track(at: CGPoint(x: 0.42, y: 0.53))])
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("a zone the item is heading into reports as settling")
    func approachReportsSettling() {
        let c = mouthClock()
        c.tick([track(at: CGPoint(x: 0.60, y: 0.35))])
        c.tick([track(at: CGPoint(x: 0.53, y: 0.42))])
        c.tick([track(at: CGPoint(x: 0.46, y: 0.49))])
        c.tick([track(at: CGPoint(x: 0.42, y: 0.53))])
        #expect(c.tick([]).settlingZoneIDs == [mouthZone.id])
    }

    // MARK: - Dwell

    @Test("passing over a zone without dwelling is not a throw")
    func flyOverIsNotAThrow() {
        let c = clock(dwell: 4)
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 3)
        // Back out into the gap and away down it, so the last motion points at no bin either.
        c.tick([track(centerX: 0.5, centerY: 0.5)])
        c.tick([track(centerX: 0.5, centerY: 0.7)])
        c.tick([track(centerX: 0.5, centerY: 0.9)])
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("moving between zones restarts the dwell counter")
    func zoneSwitchRestartsDwell() {
        let c = clock()
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 5)
        c.tick([track(centerX: 0.8)])
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("frozen boxes do not accrue dwell")
    func coastingDoesNotCountTowardDwell() {
        let c = clock(dwell: 3)
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)])
        for miss in 1...3 {
            c.tick([track(centerX: 0.2, misses: miss)])
        }
        // Without the coasting rule the freeze frames alone would clear the threshold.
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("real detections still reach the threshold through a coast")
    func coastingPreservesEarnedDwell() {
        let c = clock(dwell: 3)
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 3)
        for miss in 1...3 {
            c.tick([track(centerX: 0.2, misses: miss)])
        }
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.dwellFrames == 3)
    }

    @Test("deposit scores the raw YOLO class, not the overlay lock")
    func rawClassOutvotesLockedLabel() {
        let c = clock(dwell: 3)
        c.tick([
            track(classKey: "organic", centerX: 0.5, rawClassKey: "residual", rawConf: 0.95),
        ])
        c.tick(
            [track(classKey: "organic", centerX: 0.2, rawClassKey: "residual", rawConf: 0.95)],
            times: 3
        )
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.classKey == "residual")
    }

    // MARK: - Overlay state

    @Test("a zone reports occupied, then armed, then settling")
    func overlayStatesFollowTheObject() {
        let c = clock(dwell: 2)
        c.tick([track(centerX: 0.5)])

        let first = c.tick([track(centerX: 0.2)])
        #expect(first.occupiedZoneIDs == [organicZone.id])
        #expect(first.armedZoneIDs.isEmpty)

        let armed = c.tick([track(centerX: 0.2)])
        #expect(armed.armedZoneIDs == [organicZone.id])

        let settling = c.tick([])
        #expect(settling.occupiedZoneIDs.isEmpty)
        #expect(settling.settlingZoneIDs == [organicZone.id])
        #expect(settling.deposits.isEmpty)
    }

    @Test("an ineligible item in a zone never reports as settling")
    func binContentsNeverSettle() {
        let c = clock(dwell: 2)
        c.tick([track(centerX: 0.2)], times: 3)
        let settling = c.tick([])
        #expect(settling.settlingZoneIDs.isEmpty)
    }
}
