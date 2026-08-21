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
        #expect(frame.statuses[zone.id]?.confidence ?? 0 >= 0.90)
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
        let bindings = [zoneA.id: [5], zoneB.id: [9]]

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

    @Test("Multi-tag partial occlusion keeps bin open")
    func multiTagPartialOcclusion() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone(name: "Organic Bin")
        let bindings = [zone.id: [0, 1, 2]]

        // Only Tag #2 is visible (Tags #0 and #1 occluded by user hand)
        let tag2 = makeTag(id: 2, timestamp: 100.0)
        detector.ingest(tags: [tag2], timestamp: 100.0)

        let frame = detector.update(zones: [zone], tagBindings: bindings, timestamp: 100.0)
        #expect(frame.statuses[zone.id]?.state == .open)
        #expect(frame.statuses[zone.id]?.tagID == 2)
        #expect(frame.statuses[zone.id]?.matchedTagIDs == [2])
        #expect(frame.statuses[zone.id]?.boundTagIDs == [0, 1, 2])
        #expect(frame.openZoneIDs.contains(zone.id))
    }

    @Test("Multi-tag all tags occluded transitions to closed after timeout")
    func multiTagAllOccluded() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone(name: "Organic Bin")
        let bindings = [zone.id: [0, 1, 2]]
        let config = AprilTagConfig(staleTimeout: 0.30)

        // t=100.0: Tag #1 is visible
        detector.ingest(tags: [makeTag(id: 1, timestamp: 100.0)], timestamp: 100.0)
        _ = detector.update(zones: [zone], tagBindings: bindings, config: config, timestamp: 100.0)

        // t=100.15: All tags occluded, within timeout -> still open
        let frame1 = detector.update(zones: [zone], tagBindings: bindings, config: config, timestamp: 100.15)
        #expect(frame1.statuses[zone.id]?.state == .open)

        // t=100.35: All tags occluded, past timeout -> closed
        let frame2 = detector.update(zones: [zone], tagBindings: bindings, config: config, timestamp: 100.35)
        #expect(frame2.statuses[zone.id]?.state == .closed)
        #expect(frame2.closedZoneIDs.contains(zone.id))
    }

    @Test("Multi-tag confidence scales with number of detected tags")
    func multiTagConfidenceScaling() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone(name: "Organic Bin")
        let bindings = [zone.id: [0, 1, 2]]

        // 1 of 3 tags visible
        detector.ingest(tags: [makeTag(id: 0, timestamp: 100.0)], timestamp: 100.0)
        let frame1 = detector.update(zones: [zone], tagBindings: bindings, timestamp: 100.0)
        let conf1 = frame1.statuses[zone.id]?.confidence ?? 0

        // 3 of 3 tags visible
        detector.ingest(
            tags: [
                makeTag(id: 0, timestamp: 101.0),
                makeTag(id: 1, timestamp: 101.0),
                makeTag(id: 2, timestamp: 101.0)
            ],
            timestamp: 101.0
        )
        let frame3 = detector.update(zones: [zone], tagBindings: bindings, timestamp: 101.0)
        let conf3 = frame3.statuses[zone.id]?.confidence ?? 0

        #expect(conf3 > conf1)
        #expect(frame3.statuses[zone.id]?.matchedTagIDs.count == 3)
    }

    @Test("Default 3-tag groups per zone index when no explicit bindings are set")
    func defaultGroupAssignments() {
        let detector = AprilTagBinStateDetector()
        let zone0 = makeZone(
            name: "Organic (Zone 0)",
            corners: [CGPoint(x: 0.0, y: 0.0), CGPoint(x: 0.3, y: 0.0), CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.0, y: 0.3)]
        )
        let zone1 = makeZone(
            name: "Residual (Zone 1)",
            corners: [CGPoint(x: 0.35, y: 0.0), CGPoint(x: 0.65, y: 0.0), CGPoint(x: 0.65, y: 0.3), CGPoint(x: 0.35, y: 0.3)]
        )
        let zone2 = makeZone(
            name: "Recyclable (Zone 2)",
            corners: [CGPoint(x: 0.7, y: 0.0), CGPoint(x: 1.0, y: 0.0), CGPoint(x: 1.0, y: 0.3), CGPoint(x: 0.7, y: 0.3)]
        )

        // Tag #4 belongs to Zone 1 default group [3, 4, 5], center inside zone1
        let tag4 = makeTag(id: 4, center: CGPoint(x: 0.5, y: 0.15), timestamp: 100.0)
        detector.ingest(tags: [tag4], timestamp: 100.0)
        let frame = detector.update(zones: [zone0, zone1, zone2], tagBindings: [:], timestamp: 100.0)

        #expect(frame.statuses[zone0.id]?.state == .closed)
        #expect(frame.statuses[zone1.id]?.state == .open)
        #expect(frame.statuses[zone1.id]?.tagID == 4)
        #expect(frame.statuses[zone2.id]?.state == .closed)
    }

    @Test("Empty zones array returns empty status frame without error")
    func emptyZonesArray() {
        let detector = AprilTagBinStateDetector()
        detector.ingest(tags: [makeTag(id: 0, timestamp: 100.0)], timestamp: 100.0)
        let frame = detector.update(zones: [], timestamp: 100.0)

        #expect(frame.statuses.isEmpty)
        #expect(frame.openZoneIDs.isEmpty)
        #expect(frame.closedZoneIDs.isEmpty)
    }

    @Test("Tag handoff within same 3-tag group keeps bin open and updates primary tag ID")
    func tagHandoffWithinGroup() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone(name: "Organic Bin")
        let bindings = [zone.id: [0, 1, 2]]

        // t=100.0: Tag #0 visible
        detector.ingest(tags: [makeTag(id: 0, timestamp: 100.0)], timestamp: 100.0)
        let frame1 = detector.update(zones: [zone], tagBindings: bindings, timestamp: 100.0)
        #expect(frame1.statuses[zone.id]?.state == .open)
        #expect(frame1.statuses[zone.id]?.tagID == 0)

        // t=100.1: Tag #0 occluded, Tag #2 becomes visible
        detector.ingest(tags: [makeTag(id: 2, timestamp: 100.1)], timestamp: 100.1)
        let frame2 = detector.update(zones: [zone], tagBindings: bindings, timestamp: 100.1)
        #expect(frame2.statuses[zone.id]?.state == .open)
        #expect(frame2.statuses[zone.id]?.tagID == 2)
        #expect(frame2.statuses[zone.id]?.matchedTagIDs == [2])

        // t=100.2: Both occluded briefly -> retains Tag #2 as remembered primary tag
        detector.ingest(tags: [], timestamp: 100.2)
        let frame3 = detector.update(zones: [zone], tagBindings: bindings, timestamp: 100.2)
        #expect(frame3.statuses[zone.id]?.state == .open)
        #expect(frame3.statuses[zone.id]?.tagID == 2)
    }

    @Test("Explicit empty binding keeps zone closed")
    func explicitEmptyBindingStaysClosed() {
        let detector = AprilTagBinStateDetector()
        let zone = makeZone(name: "Unassigned Bin")
        let bindings = [zone.id: [Int]()]

        detector.ingest(tags: [makeTag(id: 0, timestamp: 100.0)], timestamp: 100.0)
        let frame = detector.update(zones: [zone], tagBindings: bindings, timestamp: 100.0)

        #expect(frame.statuses[zone.id]?.state == .closed)
    }
}
