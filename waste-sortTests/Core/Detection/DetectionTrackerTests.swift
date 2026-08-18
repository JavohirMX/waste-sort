import CoreGraphics
import Testing
@testable import waste_sort

struct DetectionTrackerTests {
    @Test func unmatchedCoastFreezesAtLastMatchedCenter() {
        let tracker = DetectionTracker()
        tracker.confirmHits = 1
        tracker.maxMisses = 3
        tracker.emaAlpha = 1.0
        tracker.boxInflate = 0
        tracker.maxSpeed = 2.0
        tracker.iouThreshold = 0.2

        let t0: CFAbsoluteTime = 100
        // Small steps so IoU association keeps the same track.
        let moving = [
            detection(x: 0.30, y: 0.40),
            detection(x: 0.34, y: 0.40),
            detection(x: 0.38, y: 0.40),
        ]

        var trackID: Int?
        var lastMatched: TrackedDetection?
        for (i, det) in moving.enumerated() {
            let emitted = tracker.update([det], timestamp: t0 + CFAbsoluteTime(i) * 0.05)
            #expect(emitted.count == 1)
            if let id = trackID {
                #expect(emitted[0].id == id)
            } else {
                trackID = emitted[0].id
            }
            lastMatched = emitted[0]
        }

        let frozenCenter = CGPoint(x: lastMatched!.displayXywhn.midX, y: lastMatched!.displayXywhn.midY)

        for miss in 1...3 {
            let emitted = tracker.update([], timestamp: t0 + CFAbsoluteTime(2 + miss) * 0.05)
            #expect(emitted.count == 1, "expected frozen coast on miss \(miss)")
            let coast = emitted[0]
            #expect(coast.id == trackID)
            #expect(abs(coast.displayXywhn.midX - frozenCenter.x) < 1e-5)
            #expect(abs(coast.displayXywhn.midY - frozenCenter.y) < 1e-5)
        }

        let afterDrop = tracker.update([], timestamp: t0 + 0.30)
        #expect(afterDrop.isEmpty)
    }

    @Test func dropsAfterMaxMisses() {
        let tracker = DetectionTracker()
        tracker.confirmHits = 1
        tracker.maxMisses = 2
        tracker.emaAlpha = 1.0
        tracker.boxInflate = 0

        let t0: CFAbsoluteTime = 50
        _ = tracker.update([detection(x: 0.4, y: 0.4)], timestamp: t0)
        #expect(tracker.update([], timestamp: t0 + 0.05).count == 1)
        #expect(tracker.update([], timestamp: t0 + 0.10).count == 1)
        #expect(tracker.update([], timestamp: t0 + 0.15).isEmpty)
    }
}

private func detection(x: CGFloat, y: CGFloat, size: CGFloat = 0.12) -> RawDetection {
    RawDetection(
        classKey: "residual",
        className: "residual",
        conf: 0.9,
        xywhn: CGRect(x: x - size * 0.5, y: y - size * 0.5, width: size, height: size)
    )
}
