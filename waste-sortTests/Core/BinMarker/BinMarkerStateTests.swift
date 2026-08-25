import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

private func detection(
    slot: Int,
    style: BinMarkerStyle = .color,
    degraded: Bool = false,
    at center: CGPoint = CGPoint(x: 0.5, y: 0.5),
    timestamp: CFAbsoluteTime = 0,
    patternOverride: Int? = nil
) -> BinMarkerDetection {
    let marker = BinMarkerSlot.all[slot]
    return BinMarkerDetection(
        patternID: patternOverride ?? (degraded ? nil : marker.pattern.id),
        inkID: style == .mono ? nil : marker.ink.id,
        orientation: .horizontal,
        bounds: CGRect(x: center.x - 0.06, y: center.y - 0.02, width: 0.12, height: 0.04),
        lineCount: 6,
        unitSamples: 6,
        chroma: CGPoint(x: marker.ink.cb, y: marker.ink.cr),
        timestamp: timestamp
    )
}

private func zones(_ count: Int) -> [DropZone] {
    (0..<count).map { index in
        DropZone(
            name: "Zone \(index)",
            binID: BinGuide.all[min(index, BinGuide.all.count - 1)].id,
            corners: DropZone.rect(
                CGRect(x: 0.05 + Double(index) * 0.3, y: 0.4, width: 0.25, height: 0.3)
            )
        )
    }
}

@Suite("Bin marker identity")
struct BinMarkerIdentityTests {
    @Test("A slot pairs one rhythm with one ink")
    func slotsPairRhythmAndInk() {
        #expect(BinMarkerSlot.all.count == 3)
        for slot in BinMarkerSlot.all {
            #expect(slot.pattern.id == slot.index + 1)
            #expect(BinMarkerSlot.withInkID(slot.ink.id)?.index == slot.index)
            #expect(BinMarkerSlot.withPatternID(slot.pattern.id)?.index == slot.index)
        }
    }

    @Test("Colour identity is cross-checked against the rhythm")
    func colorIdentityIsCrossChecked() {
        #expect(detection(slot: 1).slot(style: .color)?.index == 1)
        // Ink naming one bin while the rhythm names another is not a strip we printed.
        #expect(detection(slot: 1, patternOverride: 3).slot(style: .color) == nil)
        // An unreadable rhythm is allowed — carrying identity that far is what colour is for.
        #expect(detection(slot: 2, degraded: true).slot(style: .color)?.index == 2)
    }

    @Test("Mono identity comes from the rhythm alone")
    func monoIdentityNeedsRhythm() {
        #expect(detection(slot: 2, style: .mono).slot(style: .mono)?.index == 2)
        #expect(detection(slot: 2, style: .mono, degraded: true).slot(style: .mono) == nil)
    }
}

@Suite("Bin marker temporal confirmation")
struct BinMarkerTemporalFilterTests {
    @Test("One sighting is never enough")
    func oneSightingIsNotEnough() {
        let filter = BinMarkerTemporalFilter()
        #expect(filter.filter([detection(slot: 0)], style: .color, timestamp: 100).isEmpty)
        #expect(filter.filter([detection(slot: 0)], style: .color, timestamp: 100.1).count == 1)
    }

    /// A strip on an open bin does not move. Something strip-shaped that does is a sleeve or a
    /// carton being carried past.
    @Test("A travelling strip is never confirmed")
    func movingStripIsRejected() {
        let filter = BinMarkerTemporalFilter()
        var time = 100.0
        var trusted = 0
        for step in 0..<6 {
            let moved = CGPoint(x: 0.2 + Double(step) * 0.09, y: 0.5)
            trusted += filter.filter(
                [detection(slot: 0, at: moved, timestamp: time)],
                style: .color,
                timestamp: time
            ).count
            time += 0.08
        }
        #expect(trusted == 0)
    }

    @Test("A degraded reading needs one sighting more")
    func degradedNeedsAnExtraHit() {
        let filter = BinMarkerTemporalFilter()
        #expect(filter.filter([detection(slot: 0, degraded: true)], style: .color, timestamp: 100).isEmpty)
        #expect(filter.filter([detection(slot: 0, degraded: true)], style: .color, timestamp: 100.1).isEmpty)
        #expect(filter.filter([detection(slot: 0, degraded: true)], style: .color, timestamp: 100.2).count == 1)
    }

    @Test("Confirmation survives a gap, then lapses")
    func confirmationExpires() {
        let filter = BinMarkerTemporalFilter()
        _ = filter.filter([detection(slot: 0)], style: .color, timestamp: 100)
        _ = filter.filter([detection(slot: 0)], style: .color, timestamp: 100.1)
        #expect(filter.filter([detection(slot: 0)], style: .color, timestamp: 101.3).count == 1)
        #expect(filter.filter([detection(slot: 0)], style: .color, timestamp: 110).isEmpty)
    }
}

@Suite("Bin marker openness")
struct BinMarkerStateDetectorTests {
    @Test("A visible strip opens its bin, and only its bin")
    func visibleStripOpensOneBin() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(detections: [detection(slot: 1, timestamp: 100)], timestamp: 100)
        let frame = detector.update(zones: list, style: .color, timestamp: 100)
        #expect(frame.statuses[list[1].id]?.state == .open)
        #expect(frame.statuses[list[0].id]?.state == .closed)
        #expect(frame.statuses[list[2].id]?.state == .closed)
        #expect(frame.openZoneIDs == [list[1].id])
    }

    /// Most dropouts are an arm reaching in, not a lid coming down.
    @Test("Openness coasts through a dropout, then gives up")
    func opennessCoasts() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(detections: [detection(slot: 0, timestamp: 100)], timestamp: 100)
        _ = detector.update(zones: list, style: .color, timestamp: 100)

        let coasting = detector.update(zones: list, style: .color, timestamp: 101)
        #expect(coasting.statuses[list[0].id]?.state == .open)
        #expect(coasting.statuses[list[0].id]?.isCoasting == true)
        #expect((coasting.statuses[list[0].id]?.confidence ?? 1) < 0.95)

        let lapsed = detector.update(zones: list, style: .color, timestamp: 103)
        #expect(lapsed.statuses[list[0].id]?.state == .closed)
    }

    @Test("Bindings decide which strip belongs to which bin")
    func bindingsAreHonoured() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        let bindings: [UUID: Int] = [list[0].id: 2, list[2].id: 0]
        detector.ingest(detections: [detection(slot: 2, timestamp: 100)], timestamp: 100)
        let frame = detector.update(zones: list, bindings: bindings, style: .color, timestamp: 100)
        #expect(frame.statuses[list[0].id]?.state == .open)
        #expect(frame.statuses[list[2].id]?.state == .closed)
    }

    @Test("A degraded sighting opens the bin but says it is degraded")
    func degradedSightingIsFlagged() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 0, degraded: true, timestamp: 100)],
            timestamp: 100
        )
        let frame = detector.update(zones: list, style: .color, timestamp: 100)
        #expect(frame.statuses[list[0].id]?.state == .open)
        #expect(frame.statuses[list[0].id]?.isDegraded == true)
        #expect((frame.statuses[list[0].id]?.confidence ?? 1) < 0.95)
    }

    @Test("A strip whose halves disagree opens nothing")
    func contradictoryStripOpensNothing() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 0, timestamp: 100, patternOverride: 3)],
            timestamp: 100
        )
        let frame = detector.update(zones: list, style: .color, timestamp: 100)
        #expect(frame.openZoneIDs.isEmpty)
    }

    @Test("Dropping a zone forgets its history")
    func removedZonesArePruned() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(detections: [detection(slot: 0, timestamp: 100)], timestamp: 100)
        _ = detector.update(zones: list, style: .color, timestamp: 100)
        let frame = detector.update(zones: Array(list.dropFirst()), style: .color, timestamp: 100.2)
        #expect(frame.statuses.count == 2)
        #expect(frame.statuses[list[0].id] == nil)
    }

    /// `ZoneDepositDetector` is not told which detector is running, and must not be.
    @Test("Marker state feeds the deposit gate unchanged")
    func markerStateFeedsTheGate() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(detections: [detection(slot: 1, timestamp: 100)], timestamp: 100)
        let frame = detector.update(zones: list, style: .color, timestamp: 100)
        let gate = FrameBinOpenState(markerFrame: frame, zones: list)
        #expect(gate.isOpen(binID: list[1].binID))
        #expect(!gate.isOpen(binID: list[0].binID))
    }

    @Test("The snapshot routes the gate to whichever detector is selected")
    func snapshotRoutesToSelectedSource() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(detections: [detection(slot: 1, timestamp: 100)], timestamp: 100)
        let markerFrame = detector.update(zones: list, style: .color, timestamp: 100)

        // With markers selected, the marker frame decides: bin 1 open, the rest shut.
        let usingMarkers = BinOpennessSnapshot(source: .marker, marker: markerFrame)
        #expect(usingMarkers.openState(zones: list).isOpen(binID: list[1].binID))
        #expect(!usingMarkers.openState(zones: list).isOpen(binID: list[0].binID))

        // With AprilTags selected, the same marker frame must not gate anything; an empty tag
        // frame names no closed zone, so every bin reads open.
        let usingTags = BinOpennessSnapshot(source: .aprilTag, marker: markerFrame)
        #expect(usingTags.openState(zones: list).isOpen(binID: list[0].binID))
    }
}
