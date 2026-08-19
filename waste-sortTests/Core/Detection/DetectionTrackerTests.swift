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

    @Test func classFlickerKeepsIdAndStableClass() {
        let tracker = stickyTracker()
        tracker.confirmHits = 2
        let t0: CFAbsoluteTime = 10
        let box = (x: CGFloat(0.4), y: CGFloat(0.4))

        #expect(
            tracker.update(
                [detection(x: box.x, y: box.y, classKey: "organic")],
                timestamp: t0
            ).isEmpty
        )

        var id: Int?
        for i in 1..<3 {
            let emitted = tracker.update(
                [detection(x: box.x, y: box.y, classKey: "organic")],
                timestamp: t0 + CFAbsoluteTime(i) * 0.05
            )
            #expect(emitted.count == 1)
            #expect(emitted[0].classKey == "organic")
            if let id {
                #expect(emitted[0].id == id)
            } else {
                id = emitted[0].id
            }
        }

        let flickered = tracker.update(
            [detection(x: box.x, y: box.y, classKey: "residual", conf: 0.99)],
            timestamp: t0 + 0.20
        )
        #expect(flickered.count == 1)
        #expect(flickered[0].id == id)
        #expect(flickered[0].classKey == "organic")
        #expect(flickered[0].rawClassKey == "residual")
        #expect(flickered[0].conf < 0.99)
    }

    @Test func sustainedClassChangeSwitchesLabel() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        let t0: CFAbsoluteTime = 20
        let box = (x: CGFloat(0.4), y: CGFloat(0.4))

        let confirmed = tracker.update(
            [detection(x: box.x, y: box.y, classKey: "organic")],
            timestamp: t0
        )
        #expect(confirmed.count == 1)
        let id = confirmed[0].id
        #expect(confirmed[0].classKey == "organic")

        var last: [TrackedDetection] = []
        for i in 1...3 {
            last = tracker.update(
                [detection(x: box.x, y: box.y, classKey: "residual")],
                timestamp: t0 + CFAbsoluteTime(i) * 0.05
            )
            #expect(last.count == 1)
            #expect(last[0].id == id)
        }
        #expect(last[0].classKey == "residual")
        #expect(last[0].rawClassKey == "residual")
    }

    @Test func pendingStreakResetsWhenStableClassReturns() {
        let tracker = stickyTracker()
        tracker.confirmHits = 2
        let t0: CFAbsoluteTime = 30
        let box = (x: CGFloat(0.4), y: CGFloat(0.4))

        #expect(
            tracker.update(
                [detection(x: box.x, y: box.y, classKey: "organic")],
                timestamp: t0
            ).isEmpty
        )
        let confirmed = tracker.update(
            [detection(x: box.x, y: box.y, classKey: "organic")],
            timestamp: t0 + 0.05
        )
        #expect(confirmed.count == 1)
        let id = confirmed[0].id
        #expect(confirmed[0].classKey == "organic")

        let sequence: [(CFAbsoluteTime, String)] = [
            (t0 + 0.10, "residual"),
            (t0 + 0.15, "organic"),
        ]
        for (timestamp, classKey) in sequence {
            let emitted = tracker.update(
                [detection(x: box.x, y: box.y, classKey: classKey)],
                timestamp: timestamp
            )
            #expect(emitted.count == 1)
            #expect(emitted[0].id == id)
            #expect(emitted[0].classKey == "organic")
        }
    }

    @Test func crossClassMatchDoesNotCountAsMiss() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        tracker.maxMisses = 1
        let t0: CFAbsoluteTime = 40

        let confirmed = tracker.update(
            [detection(x: 0.4, y: 0.4, classKey: "organic")],
            timestamp: t0
        )
        #expect(confirmed.count == 1)
        let id = confirmed[0].id

        let rematched = tracker.update(
            [detection(x: 0.4, y: 0.4, classKey: "residual")],
            timestamp: t0 + 0.05
        )
        #expect(rematched.count == 1)
        #expect(rematched[0].id == id)
        #expect(rematched[0].classKey == "organic")
        #expect(rematched[0].misses == 0)

        let afterOneEmpty = tracker.update([], timestamp: t0 + 0.10)
        #expect(afterOneEmpty.count == 1)
        #expect(afterOneEmpty[0].id == id)
    }

    @Test func overlappingDifferentClassesStaySeparate() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        let t0: CFAbsoluteTime = 50

        let pair = [
            detection(x: 0.30, y: 0.40, size: 0.20, classKey: "organic"),
            detection(x: 0.42, y: 0.40, size: 0.20, classKey: "residual"),
        ]
        var ids: Set<Int> = []
        for i in 0..<2 {
            let emitted = tracker.update(pair, timestamp: t0 + CFAbsoluteTime(i) * 0.05)
            #expect(emitted.count == 2)
            let keys = Set(emitted.map(\.classKey))
            #expect(keys == ["organic", "residual"])
            ids.formUnion(emitted.map(\.id))
        }
        #expect(ids.count == 2)
    }

    @Test func sameFrameDualClassKeepsOneResidualTrack() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        let t0: CFAbsoluteTime = 70
        let box = (x: CGFloat(0.4), y: CGFloat(0.4))

        let confirmed = tracker.update(
            [detection(x: box.x, y: box.y, classKey: "residual")],
            timestamp: t0
        )
        #expect(confirmed.count == 1)
        let id = confirmed[0].id

        let dual = tracker.update(
            [
                detection(x: box.x, y: box.y, classKey: "residual", conf: 0.9),
                detection(x: box.x, y: box.y, classKey: "clean_inorganic", conf: 0.8),
            ],
            timestamp: t0 + 0.05
        )
        #expect(dual.count == 1)
        #expect(dual[0].id == id)
        #expect(dual[0].classKey == "residual")
    }

    @Test func shiftedClassSwapKeepsSameTrack() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        tracker.crossClassIouThreshold = 0.35
        let t0: CFAbsoluteTime = 80

        let confirmed = tracker.update(
            [detection(x: 0.40, y: 0.40, size: 0.12, classKey: "residual")],
            timestamp: t0
        )
        #expect(confirmed.count == 1)
        let id = confirmed[0].id

        let shifted = tracker.update(
            [detection(x: 0.455, y: 0.40, size: 0.12, classKey: "organic")],
            timestamp: t0 + 0.05
        )
        #expect(shifted.count == 1)
        #expect(shifted[0].id == id)
        #expect(shifted[0].classKey == "residual")
    }

    @Test func relabelAtTrackerIouKeepsIdAndVotes() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        tracker.iouThreshold = 0.3
        tracker.crossClassIouThreshold = 0.35
        let t0: CFAbsoluteTime = 85

        let confirmed = tracker.update(
            [detection(x: 0.40, y: 0.40, size: 0.12, classKey: "organic")],
            timestamp: t0
        )
        #expect(confirmed.count == 1)
        let id = confirmed[0].id

        // Shift ~0.062 → IoU ~0.32, inside the old [0.30, 0.35) dead zone.
        let relabel = tracker.update(
            [detection(x: 0.462, y: 0.40, size: 0.12, classKey: "residual", conf: 0.88)],
            timestamp: t0 + 0.05
        )
        #expect(relabel.count == 1)
        #expect(relabel[0].id == id)
        #expect(relabel[0].misses == 0)
        #expect(relabel[0].classKey == "organic")
        #expect(relabel[0].rawClassKey == "residual")
        #expect(relabel[0].rawConf == 0.88)
    }

    @Test func firstFrameDualClassSpawnsSingleTrack() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        let emitted = tracker.update(
            [
                detection(x: 0.4, y: 0.4, classKey: "clean_inorganic", conf: 0.7),
                detection(x: 0.4, y: 0.4, classKey: "residual", conf: 0.92),
            ],
            timestamp: 90
        )
        #expect(emitted.count == 1)
        #expect(emitted[0].classKey == "residual")
    }

    @Test func lowIouClassChangeSpawnsNewTrack() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        let t0: CFAbsoluteTime = 60

        let organic = tracker.update(
            [detection(x: 0.25, y: 0.40, classKey: "organic")],
            timestamp: t0
        )
        #expect(organic.count == 1)
        let organicID = organic[0].id

        let both = tracker.update(
            [detection(x: 0.75, y: 0.40, classKey: "residual")],
            timestamp: t0 + 0.05
        )
        #expect(both.count == 2)
        let residual = both.first { $0.classKey == "residual" }
        let frozenOrganic = both.first { $0.id == organicID }
        #expect(residual != nil)
        #expect(frozenOrganic != nil)
        #expect(residual?.id != organicID)
        #expect(frozenOrganic?.classKey == "organic")
    }

    @Test func confirmingRequiresAgreeingClass() {
        let tracker = stickyTracker()
        tracker.confirmHits = 2
        let t0: CFAbsoluteTime = 95
        let box = (x: CGFloat(0.4), y: CGFloat(0.4))

        #expect(
            tracker.update(
                [detection(x: box.x, y: box.y, classKey: "organic")],
                timestamp: t0
            ).isEmpty
        )
        #expect(
            tracker.update(
                [detection(x: box.x, y: box.y, classKey: "residual")],
                timestamp: t0 + 0.05
            ).isEmpty
        )
        let emitted = tracker.update(
            [detection(x: box.x, y: box.y, classKey: "residual")],
            timestamp: t0 + 0.10
        )
        #expect(emitted.count == 1)
        #expect(emitted[0].classKey == "residual")
    }

    @Test func overlappingYoungerTrackReappearsWithSameID() {
        let tracker = stickyTracker()
        tracker.confirmHits = 1
        tracker.emaAlpha = 1.0
        tracker.maxSpeed = 8.0
        tracker.iouThreshold = 0.15
        tracker.crossClassIouThreshold = 0.15
        let t0: CFAbsoluteTime = 110
        let size: CGFloat = 0.20

        func pair(residualX: CGFloat) -> [RawDetection] {
            [
                detection(x: 0.20, y: 0.40, size: size, classKey: "organic"),
                detection(x: residualX, y: 0.40, size: size, classKey: "residual"),
            ]
        }

        let confirmed = tracker.update(pair(residualX: 0.55), timestamp: t0)
        #expect(confirmed.count == 2)
        let organicID = confirmed.first { $0.classKey == "organic" }!.id
        let residualID = confirmed.first { $0.classKey == "residual" }!.id

        var t = t0 + 0.05
        var residualX: CGFloat = 0.55
        var overlapped: [TrackedDetection] = []
        while residualX > 0.27 {
            residualX -= 0.04
            overlapped = tracker.update(pair(residualX: residualX), timestamp: t)
            t += 0.05
        }
        #expect(overlapped.count == 1)
        #expect(overlapped[0].id == organicID)

        var separated: [TrackedDetection] = []
        while residualX < 0.55 {
            residualX += 0.04
            separated = tracker.update(pair(residualX: residualX), timestamp: t)
            t += 0.05
        }
        #expect(Set(separated.map(\.id)) == [organicID, residualID])
    }
}

private func stickyTracker() -> DetectionTracker {
    let tracker = DetectionTracker()
    tracker.emaAlpha = 1.0
    tracker.boxInflate = 0
    tracker.iouThreshold = 0.3
    tracker.crossClassIouThreshold = 0.5
    tracker.classLockWindow = 0.10
    return tracker
}

private func detection(
    x: CGFloat,
    y: CGFloat,
    size: CGFloat = 0.12,
    classKey: String = "residual",
    conf: Float = 0.9
) -> RawDetection {
    RawDetection(
        classKey: classKey,
        className: classKey,
        conf: conf,
        xywhn: CGRect(x: x - size * 0.5, y: y - size * 0.5, width: size, height: size)
    )
}
