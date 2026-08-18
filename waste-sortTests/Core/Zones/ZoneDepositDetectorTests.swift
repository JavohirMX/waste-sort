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

    private func track(id: Int = 1, classKey: String = "organic", centerX: CGFloat) -> TrackedDetection {
        TrackedDetection(
            id: id,
            classKey: classKey,
            className: classKey,
            conf: 0.9,
            displayXywhn: CGRect(x: centerX - 0.05, y: 0.45, width: 0.1, height: 0.1)
        )
    }

    private func makeDetector(dwell: Int = 3) -> ZoneDepositDetector {
        let detector = ZoneDepositDetector()
        detector.requiredDwellFrames = dwell
        return detector
    }

    /// One frame in the gap between the bins, so the tracks become eligible to enter.
    private func seeOutside(_ detector: ZoneDepositDetector, ids: [Int] = [1]) {
        _ = detector.update(
            tracks: ids.map { track(id: $0, centerX: 0.5) },
            zones: zones
        )
    }

    @Test("dwelling then disappearing counts as a deposit")
    func dwellThenDeath() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<3 {
            #expect(detector.update(tracks: [track(centerX: 0.2)], zones: zones).isEmpty)
        }
        let deposits = detector.update(tracks: [], zones: zones)
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
            _ = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        }
        // Moves into the gap between the bins, then is lost there.
        #expect(detector.update(tracks: [track(centerX: 0.5)], zones: zones).isEmpty)
        #expect(detector.update(tracks: [], zones: zones).isEmpty)
    }

    @Test("disappearing before the dwell threshold is not a deposit")
    func tooShort() {
        let detector = makeDetector(dwell: 4)
        seeOutside(detector)
        for _ in 0..<3 {
            _ = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        }
        #expect(detector.update(tracks: [], zones: zones).isEmpty)
    }

    @Test("moving between zones restarts the dwell counter")
    func zoneSwitchRestartsDwell() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<5 {
            _ = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        }
        _ = detector.update(tracks: [track(centerX: 0.8)], zones: zones)
        // Only one frame in the residual zone so far — not armed yet.
        #expect(detector.update(tracks: [], zones: zones).isEmpty)
    }

    @Test("a mismatched category is recorded as incorrect")
    func mismatchIsIncorrect() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<3 {
            _ = detector.update(
                tracks: [track(classKey: "organic", centerX: 0.8)],
                zones: zones
            )
        }
        let deposits = detector.update(tracks: [], zones: zones)
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
            _ = detector.update(tracks: both, zones: zones)
        }
        let deposits = detector.update(tracks: [], zones: zones)
        #expect(deposits.map(\.trackID) == [1, 2])
        #expect(deposits.filter { $0.isCorrect }.count == 2)
    }

    @Test("no zones means no deposits and no retained state")
    func noZones() {
        let detector = makeDetector(dwell: 1)
        _ = detector.update(tracks: [track(centerX: 0.2)], zones: [])
        #expect(detector.update(tracks: [], zones: []).isEmpty)
    }

    @Test("a redetected track does not fire twice")
    func firesOncePerTrack() {
        let detector = makeDetector()
        seeOutside(detector)
        for _ in 0..<3 {
            _ = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        }
        #expect(detector.update(tracks: [], zones: zones).count == 1)
        #expect(detector.update(tracks: [], zones: zones).isEmpty)
    }

    @Test("an item first detected inside a zone is never counted")
    func materialisedInsideIsIgnored() {
        let detector = makeDetector()
        for _ in 0..<10 {
            _ = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        }
        #expect(detector.update(tracks: [], zones: zones).isEmpty)
    }

    @Test("entering from outside then dwelling counts")
    func entersFromOutside() {
        let detector = makeDetector()
        _ = detector.update(tracks: [track(centerX: 0.5)], zones: zones)
        for _ in 0..<3 {
            _ = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        }
        let deposits = detector.update(tracks: [], zones: zones)
        #expect(deposits.count == 1)
        #expect(deposits.first?.zoneID == organicZone.id)
    }

    @Test("eligibility does not leak to a later track reusing the id")
    func eligibilityIsDroppedWithTheTrack() {
        let detector = makeDetector()
        // Track 1 is seen outside, then vanishes without ever entering.
        _ = detector.update(tracks: [track(id: 1, centerX: 0.5)], zones: zones)
        _ = detector.update(tracks: [], zones: zones)
        // A new item with the same id shows up already inside the bin.
        for _ in 0..<5 {
            _ = detector.update(tracks: [track(id: 1, centerX: 0.2)], zones: zones)
        }
        #expect(detector.update(tracks: [], zones: zones).isEmpty)
    }

    @Test("leaving a zone and coming back still counts")
    func reentryCounts() {
        let detector = makeDetector()
        _ = detector.update(tracks: [track(centerX: 0.5)], zones: zones)
        _ = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        _ = detector.update(tracks: [track(centerX: 0.5)], zones: zones)
        for _ in 0..<3 {
            _ = detector.update(tracks: [track(centerX: 0.2)], zones: zones)
        }
        #expect(detector.update(tracks: [], zones: zones).count == 1)
    }
}
