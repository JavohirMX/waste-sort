import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

@Suite("AprilTagModels Tests")
struct AprilTagModelsTests {
    @Test("BinOpennessState properties and behavior")
    func binOpennessState() {
        #expect(BinOpennessState.open.acceptsItems == true)
        #expect(BinOpennessState.closed.acceptsItems == false)
        #expect(BinOpennessState.unknown.acceptsItems == false)

        #expect(BinOpennessState.open.displayName == "Open")
        #expect(BinOpennessState.closed.displayName == "Closed")
        #expect(BinOpennessState.unknown.displayName == "Unknown")
    }

    @Test("BinOpenness initialization and equality")
    func binOpenness() {
        let openness = BinOpenness(state: .open, confidence: 0.98, tagID: 1, lastSeenAt: 100.0)
        #expect(openness.state == .open)
        #expect(openness.confidence == 0.98)
        #expect(openness.tagID == 1)
        #expect(openness.lastSeenAt == 100.0)

        let defaultOpenness = BinOpenness()
        #expect(defaultOpenness.state == .unknown)
        #expect(defaultOpenness.confidence == 0.0)
        #expect(defaultOpenness.tagID == nil)
        #expect(defaultOpenness.lastSeenAt == 0.0)
    }

    @Test("TrackedAprilTag initialization and properties")
    func trackedAprilTag() {
        let center = CGPoint(x: 0.5, y: 0.5)
        let corners = [
            CGPoint(x: 0.4, y: 0.4),
            CGPoint(x: 0.6, y: 0.4),
            CGPoint(x: 0.6, y: 0.6),
            CGPoint(x: 0.4, y: 0.6)
        ]
        let tag = TrackedAprilTag(
            id: 2,
            center: center,
            corners: corners,
            hamming: 0,
            decisionMargin: 45.0,
            timestamp: 123.45
        )

        #expect(tag.id == 2)
        #expect(tag.center == center)
        #expect(tag.corners.count == 4)
        #expect(tag.hamming == 0)
        #expect(tag.decisionMargin == 45.0)
        #expect(tag.timestamp == 123.45)
    }

    @Test("AprilTagStatusFrame open and closed sets")
    func aprilTagStatusFrame() {
        let zone1 = UUID()
        let zone2 = UUID()
        let zone3 = UUID()

        let statuses: [UUID: BinOpenness] = [
            zone1: BinOpenness(state: .open, confidence: 0.98, tagID: 0),
            zone2: BinOpenness(state: .closed, confidence: 0.98, tagID: 1),
            zone3: BinOpenness(state: .unknown, confidence: 0.0)
        ]

        let frame = AprilTagStatusFrame(statuses: statuses, detectedTags: [], timestamp: 200.0)
        #expect(frame.openZoneIDs == [zone1])
        #expect(frame.closedZoneIDs == [zone2])
        #expect(frame.timestamp == 200.0)
    }

    @Test("AprilTagConfig defaults and custom settings")
    func aprilTagConfig() {
        let standard = AprilTagConfig.standard
        #expect(standard.tagFamilyName == "tag16h5")
        #expect(standard.staleTimeout == 2.0)
        #expect(standard.sampleInterval == 0.0)

        let custom = AprilTagConfig(tagFamilyName: "tag36h11", staleTimeout: 0.50, sampleInterval: 0.1)
        #expect(custom.tagFamilyName == "tag36h11")
        #expect(custom.staleTimeout == 0.50)
        #expect(custom.sampleInterval == 0.1)
    }
}
