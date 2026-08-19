import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

@Suite("AprilTagBinStateDetector Tests")
struct AprilTagBinStateDetectorTests {
    private func makeZone(
        id: UUID = UUID(),
        name: String = "Test Zone",
        binID: String = "organic",
        corners: [CGPoint] = [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.4, y: 0.1),
            CGPoint(x: 0.4, y: 0.4),
            CGPoint(x: 0.1, y: 0.4)
        ]
    ) -> DropZone {
        DropZone(id: id, name: name, binID: binID, corners: corners)
    }

    private func makeTag(
        id: Int,
        center: CGPoint = CGPoint(x: 0.25, y: 0.25),
        timestamp: CFAbsoluteTime = 100.0
    ) -> TrackedAprilTag {
        TrackedAprilTag(
            id: id,
            center: center,
            corners: [
                CGPoint(x: center.x - 0.05, y: center.y - 0.05),
                CGPoint(x: center.x + 0.05, y: center.y - 0.05),
                CGPoint(x: center.x + 0.05, y: center.y + 0.05),
                CGPoint(x: center.x - 0.05, y: center.y + 0.05)
            ],
            hamming: 0,
            decisionMargin: 40.0,
            timestamp: timestamp
        )
    }

    @Test("Initial state is closed when no tags are detected")
    func initialStateClosed() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone()

        let frame = detector.update(zones: [zone], timestamp: 100.0)
        #expect(frame.statuses[zone.id]?.state == .closed)
        #expect(frame.closedZoneIDs.contains(zone.id))
        #expect(!frame.openZoneIDs.contains(zone.id))
    }

    @Test("Tag detected marks zone as open")
    func tagDetectedMarksOpen() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone()
        let tag = makeTag(id: 0, timestamp: 100.0)

        detector.ingest(tags: [tag], timestamp: 100.0)
        let frame = detector.update(zones: [zone], timestamp: 100.0)

        #expect(frame.statuses[zone.id]?.state == .open)
        #expect(frame.statuses[zone.id]?.tagID == 0)
        #expect(frame.statuses[zone.id]?.confidence ?? 0 >= 0.95)
        #expect(frame.openZoneIDs.contains(zone.id))
        #expect(!frame.closedZoneIDs.contains(zone.id))
    }

    @Test("Dropout within stale timeout maintains open state")
    func dropoutWithinStaleTimeout() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone()
        let config = AprilTagConfig(staleTimeout: 0.30)

        // Frame 1: Tag is visible at t = 100.0
        detector.ingest(tags: [makeTag(id: 0, timestamp: 100.0)], timestamp: 100.0)
        _ = detector.update(zones: [zone], config: config, timestamp: 100.0)

        // Frame 2: Tag is missing at t = 100.15 (0.15s elapsed, <= 0.30s timeout)
        let frame2 = detector.update(zones: [zone], config: config, timestamp: 100.15)
        #expect(frame2.statuses[zone.id]?.state == .open)
        #expect(frame2.openZoneIDs.contains(zone.id))

        // Frame 3: Tag is missing at t = 100.35 (> 0.30s elapsed -> transition to closed)
        let frame3 = detector.update(zones: [zone], config: config, timestamp: 100.35)
        #expect(frame3.statuses[zone.id]?.state == .closed)
        #expect(frame3.closedZoneIDs.contains(zone.id))
    }

    @Test("Explicit tag bindings take precedence over index matching")
    func explicitTagBindings() {
        let detector = AprilTagBinStateDetector()
        let zoneA = makeZone(name: "Zone A")
        let zoneB = makeZone(name: "Zone B")

        // Map zoneA to Tag #5, zoneB to Tag #9
        let bindings = [zoneA.id: 5, zoneB.id: 9]

        // Tag #9 is visible
        detector.ingest(tags: [makeTag(id: 9, timestamp: 100.0)], timestamp: 100.0)
        let frame = detector.update(zones: [zoneA, zoneB], tagBindings: bindings, timestamp: 100.0)

        #expect(frame.statuses[zoneA.id]?.state == .closed)
        #expect(frame.statuses[zoneB.id]?.state == .open)
        #expect(frame.statuses[zoneB.id]?.tagID == 9)
    }

    @Test("Geometric containment fallback when no explicit binding matches")
    func geometricFallback() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone(corners: [
            CGPoint(x: 0.6, y: 0.6),
            CGPoint(x: 0.9, y: 0.6),
            CGPoint(x: 0.9, y: 0.9),
            CGPoint(x: 0.6, y: 0.9)
        ])

        // Tag #7 is at center (0.75, 0.75) which is inside zone
        let tag = makeTag(id: 7, center: CGPoint(x: 0.75, y: 0.75), timestamp: 100.0)
        detector.ingest(tags: [tag], timestamp: 100.0)

        // Zone has no binding for 7 (default index 0 wouldn't match id 7), but geometry matches
        let frame = detector.update(zones: [zone], tagBindings: [:], timestamp: 100.0)
        #expect(frame.statuses[zone.id]?.state == .open)
        #expect(frame.statuses[zone.id]?.tagID == 7)
    }

    @Test("Reset clears last seen timestamps and pending detections")
    func resetClearsState() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone()

        detector.ingest(tags: [makeTag(id: 0, timestamp: 100.0)], timestamp: 100.0)
        _ = detector.update(zones: [zone], timestamp: 100.0)

        detector.reset()

        let frame = detector.update(zones: [zone], timestamp: 100.05)
        #expect(frame.statuses[zone.id]?.state == .closed)
    }
}
