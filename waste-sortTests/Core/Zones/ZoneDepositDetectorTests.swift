import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

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

    private var zones: [DropZone] { [organicZone, residualZone] }

    private func track(
        id: Int = 1,
        classKey: String = "organic",
        centerX: CGFloat,
        misses: Int = 0
    ) -> TrackedDetection {
        TrackedDetection(
            id: id,
            classKey: classKey,
            className: classKey,
            conf: 0.9,
            displayXywhn: CGRect(x: centerX - 0.05, y: 0.45, width: 0.1, height: 0.1),
            misses: misses
        )
    }

    /// Drives the detector frame by frame at a fixed 30fps so the time-based reacquisition
    /// window is exercised deterministically.
    private final class Clock {
        let detector = ZoneDepositDetector()
        private(set) var now: CFAbsoluteTime = 1_000
        private let zones: [DropZone]
        private let frame: CFAbsoluteTime = 1.0 / 30.0

        init(zones: [DropZone], dwell: Int = 3, grace: CFAbsoluteTime = 1.4) {
            self.zones = zones
            detector.requiredDwellFrames = dwell
            detector.reacquireGrace = grace
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

    private func clock(dwell: Int = 3, grace: CFAbsoluteTime = 1.4) -> Clock {
        Clock(zones: zones, dwell: dwell, grace: grace)
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
        // Reappears in the zone, then is carried back out and put down elsewhere.
        c.tick([track(id: 2, centerX: 0.2)])
        c.tick([track(id: 2, centerX: 0.5)], times: 3)
        #expect(c.waitOutGrace().isEmpty)
    }

    @Test("a relabelled item is the same item, not a new one")
    func classChangeIsNotANewItem() {
        let c = clock()
        c.tick([track(id: 1, classKey: "organic", centerX: 0.5)])
        c.tick([track(id: 1, classKey: "organic", centerX: 0.2)], times: 3)
        c.idle(seconds: 0.3)
        // The tracker refuses to associate across a class change, so this is a new id
        // with a different label — but it is the same cup.
        c.tick([track(id: 2, classKey: "residual", centerX: 0.2)], times: 2)
        let deposits = c.waitOutGrace()
        #expect(deposits.count == 1)
        #expect(deposits.first?.classesSeen == 2)
        // Organic had more confidence behind it across the object's life.
        #expect(deposits.first?.classKey == "organic")
    }

    /// Reproduces what `DetectionTracker` actually emits on a relabel, which is not a clean
    /// gap: it cannot associate the new label with the old track, so it coasts the old one
    /// for `maxMisses` frames *while* the new one is already live. Both are in the array at
    /// once. Treating the frozen box as a sighting used to strand the old object — armed,
    /// never adopted, firing a throw that never happened — and disqualify the new one for
    /// having been born inside the zone.
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
        // Two objects, and the newcomer was born inside the zone, so only one is credited.
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

    @Test("an item that only ever appeared inside a zone is never counted")
    func materialisedInsideIsIgnored() {
        let c = clock()
        c.tick([track(centerX: 0.2)], times: 20)
        #expect(c.waitOutGrace().isEmpty)
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

    // MARK: - Dwell

    @Test("passing over a zone without dwelling is not a throw")
    func flyOverIsNotAThrow() {
        let c = clock(dwell: 4)
        c.tick([track(centerX: 0.5)])
        c.tick([track(centerX: 0.2)], times: 3)
        c.tick([track(centerX: 0.5)], times: 3)
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

    @Test("deposit records binWasOpen true when zone is open")
    func depositWithOpenBin() {
        let detector = ZoneDepositDetector()
        detector.requiredDwellFrames = 2
        detector.reacquireGrace = 0.5

        let t = track(id: 1, classKey: "organic", centerX: 0.5)
        _ = detector.update(tracks: [t], zones: zones, closedZoneIDs: [], timestamp: 100.0)

        let tInZone = track(id: 1, classKey: "organic", centerX: 0.2)
        _ = detector.update(tracks: [tInZone], zones: zones, closedZoneIDs: [], timestamp: 100.1)
        _ = detector.update(tracks: [tInZone], zones: zones, closedZoneIDs: [], timestamp: 100.2)

        // Item vanishes; start grace period
        _ = detector.update(tracks: [], zones: zones, closedZoneIDs: [], timestamp: 100.3)
        // Grace period elapses (> 0.5s)
        let result = detector.update(tracks: [], zones: zones, closedZoneIDs: [], timestamp: 101.0)
        #expect(result.deposits.count == 1)
        #expect(result.deposits.first?.binWasOpen == true)
    }

    @Test("deposit records binWasOpen false when zone is in closedZoneIDs")
    func depositWithClosedBin() {
        let detector = ZoneDepositDetector()
        detector.requiredDwellFrames = 2
        detector.reacquireGrace = 0.5

        let t = track(id: 2, classKey: "organic", centerX: 0.5)
        _ = detector.update(tracks: [t], zones: zones, closedZoneIDs: [organicZone.id], timestamp: 100.0)

        let tInZone = track(id: 2, classKey: "organic", centerX: 0.2)
        _ = detector.update(tracks: [tInZone], zones: zones, closedZoneIDs: [organicZone.id], timestamp: 100.1)
        _ = detector.update(tracks: [tInZone], zones: zones, closedZoneIDs: [organicZone.id], timestamp: 100.2)

        // Item vanishes; start grace period
        _ = detector.update(tracks: [], zones: zones, closedZoneIDs: [organicZone.id], timestamp: 100.3)
        // Grace period elapses (> 0.5s) while zone is closed
        let result = detector.update(tracks: [], zones: zones, closedZoneIDs: [organicZone.id], timestamp: 101.0)
        #expect(result.deposits.count == 1)
        #expect(result.deposits.first?.binWasOpen == false)
    }
}
