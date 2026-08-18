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

    private func makeDetector(dwell: Int = 3) -> ZoneDepositDetector {
        let detector = ZoneDepositDetector()
        detector.requiredDwellFrames = dwell
        return detector
    }

    /// One frame in the gap between the bins, so the tracks become eligible to enter.
    private func seeOutside(_ detector: ZoneDepositDetector, ids: [Int] = [1]) {
        _ = detector.deposits(
            tracks: ids.map { track(id: $0, centerX: 0.5) },
            zones: zones
        )
    }

    @Test("dwelling then disappearing counts as a deposit")
    func dwellThenDeath() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<3 {
            #expect(detector.deposits(tracks: [track(centerX: 0.2)], zones: zones).isEmpty)
        }
        let deposits = detector.deposits(tracks: [], zones: zones)
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneID == organicZone.id)
        #expect(deposits.first?.dwellFrames == 3)
        #expect(deposits.first?.isCorrect == true)
    }

    @Test("carrying an item out of the zone is not a deposit")
    func leavesZoneAlive() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<5 {
            _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        }
        // Moves into the gap between the bins, then is lost there.
        #expect(detector.deposits(tracks: [track(centerX: 0.5)], zones: zones).isEmpty)
        #expect(detector.deposits(tracks: [], zones: zones).isEmpty)
    }

    @Test("disappearing before the dwell threshold is not a deposit")
    func tooShort() {
        let detector = makeDetector(dwell: 4)
        seeOutside(detector)
        for _ in 0..<3 {
            _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        }
        #expect(detector.deposits(tracks: [], zones: zones).isEmpty)
    }

    @Test("moving between zones restarts the dwell counter")
    func zoneSwitchRestartsDwell() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<5 {
            _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        }
        _ = detector.deposits(tracks: [track(centerX: 0.8)], zones: zones)
        // Only one frame in the residual zone so far — not armed yet.
        #expect(detector.deposits(tracks: [], zones: zones).isEmpty)
    }

    @Test("a mismatched category is recorded as incorrect")
    func mismatchIsIncorrect() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<3 {
            _ = detector.deposits(
                tracks: [track(classKey: "organic", centerX: 0.8)],
                zones: zones
            )
        }
        let deposits = detector.deposits(tracks: [], zones: zones)
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneBinID == BinGuide.residual.id)
        #expect(deposits.first?.isCorrect == false)
    }

    @Test("two items released together produce two deposits")
    func twoAtOnce() {
        let detector = makeDetector()
        seeOutside(detector, ids: [1, 2])
        let both = [
            track(id: 1, classKey: "organic", centerX: 0.2),
            track(id: 2, classKey: "residual", centerX: 0.8),
        ]
        for _ in 0..<3 {
            _ = detector.deposits(tracks: both, zones: zones)
        }
        let deposits = detector.deposits(tracks: [], zones: zones)
        #expect(deposits.map(\.trackID) == [1, 2])
        #expect(deposits.filter { $0.isCorrect }.count == 2)
    }

    @Test("no zones means no deposits and no retained state")
    func noZones() {
        let detector = makeDetector(dwell: 1)
        _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: [])
        #expect(detector.deposits(tracks: [], zones: []).isEmpty)
    }

    @Test("a redetected track does not fire twice")
    func firesOncePerTrack() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<3 {
            _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        }
        #expect(detector.deposits(tracks: [], zones: zones).count == 1)
        #expect(detector.deposits(tracks: [], zones: zones).isEmpty)
    }

    @Test("an item first detected inside a zone is never counted")
    func materialisedInsideIsIgnored() {
        let detector = makeDetector()
        for _ in 0..<10 {
            _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        }
        #expect(detector.deposits(tracks: [], zones: zones).isEmpty)
    }

    @Test("entering from outside then dwelling counts")
    func entersFromOutside() {
        let detector = makeDetector()
        _ = detector.deposits(tracks: [track(centerX: 0.5)], zones: zones)
        for _ in 0..<3 {
            _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        }
        let deposits = detector.deposits(tracks: [], zones: zones)
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneID == organicZone.id)
    }

    @Test("eligibility does not leak to a later track reusing the id")
    func eligibilityIsDroppedWithTheTrack() {
        let detector = makeDetector()
        // Track 1 is seen outside, then vanishes without ever entering.
        _ = detector.deposits(tracks: [track(id: 1, centerX: 0.5)], zones: zones)
        _ = detector.deposits(tracks: [], zones: zones)
        // A new item with the same id shows up already inside the bin.
        for _ in 0..<5 {
            _ = detector.deposits(tracks: [track(id: 1, centerX: 0.2)], zones: zones)
        }
        #expect(detector.deposits(tracks: [], zones: zones).isEmpty)
    }

    @Test("leaving a zone and coming back still counts")
    func reentryCounts() {
        let detector = makeDetector()
        _ = detector.deposits(tracks: [track(centerX: 0.5)], zones: zones)
        _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        _ = detector.deposits(tracks: [track(centerX: 0.5)], zones: zones)
        for _ in 0..<3 {
            _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        }
        #expect(detector.deposits(tracks: [], zones: zones).count == 1)
    }

    // MARK: - Coasting

    @Test("frozen boxes do not accrue dwell")
    func coastingDoesNotCountTowardDwell() {
        let detector = makeDetector(dwell: 3)
        seeOutside(detector)
        // One real detection inside, then the tracker coasts on the last known box.
        _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        for miss in 1...3 {
            _ = detector.deposits(tracks: [track(centerX: 0.2, misses: miss)], zones: zones)
        }
        // Without the coasting rule the freeze frames alone would clear the threshold.
        #expect(detector.deposits(tracks: [], zones: zones).isEmpty)
    }

    @Test("real detections still reach the threshold through a coast")
    func coastingPreservesEarnedDwell() {
        let detector = makeDetector(dwell: 3)
        seeOutside(detector)
        for _ in 0..<3 {
            _ = detector.deposits(tracks: [track(centerX: 0.2)], zones: zones)
        }
        for miss in 1...3 {
            _ = detector.deposits(tracks: [track(centerX: 0.2, misses: miss)], zones: zones)
        }
        let deposits = detector.deposits(tracks: [], zones: zones)
        #expect(deposits.count == 1)
        #expect(deposits.first?.dwellFrames == 3)
    }

    // MARK: - Live overlay state

    @Test("a zone reports as occupied while an item sits in it")
    func occupancyFollowsTheItem() {
        let detector = makeDetector()
        #expect(detector.update(tracks: [track(centerX: 0.5)], zones: zones).occupiedZoneIDs.isEmpty)

        let inside = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        #expect(inside.occupiedZoneIDs == [organicZone.id])

        let leaving = detector.update(tracks: [track(centerX: 0.5)], zones: zones)
        #expect(leaving.occupiedZoneIDs.isEmpty)
    }

    @Test("occupancy covers items that can never be credited")
    func occupancyIncludesIneligibleItems() {
        let detector = makeDetector()
        // Never seen outside, so it can never fire — but it is visibly in the bin.
        let result = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        #expect(result.occupiedZoneIDs == [organicZone.id])
        #expect(result.armedZoneIDs.isEmpty)
    }

    @Test("a zone arms only once the dwell requirement is met")
    func armingFollowsDwell() {
        let detector = makeDetector(dwell: 3)
        seeOutside(detector)
        #expect(detector.update(tracks: [track(centerX: 0.2)], zones: zones).armedZoneIDs.isEmpty)
        #expect(detector.update(tracks: [track(centerX: 0.2)], zones: zones).armedZoneIDs.isEmpty)
        let armed = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        #expect(armed.armedZoneIDs == [organicZone.id])
        #expect(armed.occupiedZoneIDs == [organicZone.id])
    }

    @Test("two occupied zones are both reported")
    func occupancyCoversEveryZone() {
        let detector = makeDetector()
        let result = detector.update(
            tracks: [
                track(id: 1, centerX: 0.2),
                track(id: 2, classKey: "residual", centerX: 0.8),
            ],
            zones: zones
        )
        #expect(result.occupiedZoneIDs == [organicZone.id, residualZone.id])
    }
}

private extension ZoneDepositDetector {
    /// Most assertions only care about what fired, not the overlay state.
    func deposits(tracks: [TrackedDetection], zones: [DropZone]) -> [ZoneDeposit] {
        update(tracks: tracks, zones: zones).deposits
    }
}
