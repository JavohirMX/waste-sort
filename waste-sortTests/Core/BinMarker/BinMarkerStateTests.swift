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

    /// The gate is where "is this one of our prints at all" is settled. Which bin it opens is
    /// a separate question, answered by position further down.
    @Test("A strip whose halves disagree is never confirmed")
    func contradictoryStripIsRejected() {
        let filter = BinMarkerTemporalFilter()
        let contradictory = detection(slot: 0, patternOverride: 3)
        #expect(filter.filter([contradictory], style: .color, timestamp: 100).isEmpty)
        #expect(filter.filter([contradictory], style: .color, timestamp: 100.1).isEmpty)
        #expect(filter.filter([contradictory], style: .color, timestamp: 100.2).isEmpty)
    }

    /// Every bin carries the same print now, so two open bins are two strips with nothing to
    /// tell them apart but where they are. Confirming one must not confirm the other.
    @Test("Two identical strips are confirmed separately")
    func identicalStripsDoNotShareAHistory() {
        let filter = BinMarkerTemporalFilter()
        let left = CGPoint(x: 0.2, y: 0.5)
        let right = CGPoint(x: 0.8, y: 0.5)
        _ = filter.filter([detection(slot: 0, at: left)], style: .color, timestamp: 100)
        // The left strip is one sighting from trusted; the right one has never been seen.
        let second = filter.filter(
            [detection(slot: 0, at: left), detection(slot: 0, at: right)],
            style: .color, timestamp: 100.1
        )
        #expect(second.count == 1)
        #expect(second.first?.center == left)
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
    @Test("A visible strip opens the bin it appears on, and only that bin")
    func visibleStripOpensOneBin() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 1, at: list[1].centroid, timestamp: 100)],
            timestamp: 100
        )
        let frame = detector.update(zones: list, timestamp: 100)
        #expect(frame.statuses[list[1].id]?.state == .open)
        #expect(frame.statuses[list[0].id]?.state == .closed)
        #expect(frame.statuses[list[2].id]?.state == .closed)
        #expect(frame.openZoneIDs == [list[1].id])
    }

    /// The point of the whole design: the print carries no identity, so the *same* strip on a
    /// different bin opens that bin instead. Nothing is bound, nothing can be stuck on wrong.
    @Test("The same strip on another bin opens that one")
    func identityComesFromPositionAlone() {
        let list = zones(3)
        for index in [0, 2] {
            // A detector each, or the first bin is still coasting when the second is measured.
            let detector = BinMarkerStateDetector()
            detector.ingest(
                detections: [detection(slot: 1, at: list[index].centroid, timestamp: 100)],
                timestamp: 100
            )
            #expect(detector.update(zones: list, timestamp: 100).openZoneIDs == [list[index].id])
        }
    }

    @Test("A strip far from every bin opens none of them")
    func strayStripOpensNothing() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 0, at: CGPoint(x: 0.5, y: 0.02), timestamp: 100)],
            timestamp: 100
        )
        #expect(detector.update(zones: list, timestamp: 100).openZoneIDs.isEmpty)
    }

    /// Two strips landing on one bin means one of them is not a strip. The one showing more of
    /// itself wins, and a fully read rhythm beats one named by ink alone at any size.
    @Test("The stronger of two strips on one bin is the one that counts")
    func strongerSightingWins() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(detections: [
            detection(slot: 0, degraded: true, at: list[0].centroid, timestamp: 100),
            detection(slot: 0, at: list[0].centroid, timestamp: 100),
        ], timestamp: 100)
        let frame = detector.update(zones: list, timestamp: 100)
        #expect(frame.statuses[list[0].id]?.isDegraded == false)
    }

    /// Most dropouts are an arm reaching in, not a lid coming down.
    @Test("Openness coasts through a dropout, then gives up")
    func opennessCoasts() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 0, at: list[0].centroid, timestamp: 100)],
            timestamp: 100
        )
        _ = detector.update(zones: list, timestamp: 100)

        let coasting = detector.update(zones: list, timestamp: 101)
        #expect(coasting.statuses[list[0].id]?.state == .open)
        #expect(coasting.statuses[list[0].id]?.isCoasting == true)
        #expect((coasting.statuses[list[0].id]?.confidence ?? 1) < 0.95)

        let lapsed = detector.update(zones: list, timestamp: 103)
        #expect(lapsed.statuses[list[0].id]?.state == .closed)
    }

    @Test("A degraded sighting opens the bin but says it is degraded")
    func degradedSightingIsFlagged() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 0, degraded: true, at: list[0].centroid, timestamp: 100)],
            timestamp: 100
        )
        let frame = detector.update(zones: list, timestamp: 100)
        #expect(frame.statuses[list[0].id]?.state == .open)
        #expect(frame.statuses[list[0].id]?.isDegraded == true)
        #expect((frame.statuses[list[0].id]?.confidence ?? 1) < 0.95)
    }

    @Test("Dropping a zone forgets its history")
    func removedZonesArePruned() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 0, at: list[0].centroid, timestamp: 100)],
            timestamp: 100
        )
        _ = detector.update(zones: list, timestamp: 100)
        let frame = detector.update(zones: Array(list.dropFirst()), timestamp: 100.2)
        #expect(frame.statuses.count == 2)
        #expect(frame.statuses[list[0].id] == nil)
    }

    /// `ZoneDepositDetector` is not told which detector is running, and must not be.
    @Test("Marker state feeds the deposit gate unchanged")
    func markerStateFeedsTheGate() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 1, at: list[1].centroid, timestamp: 100)],
            timestamp: 100
        )
        let frame = detector.update(zones: list, timestamp: 100)
        let gate = FrameBinOpenState(markerFrame: frame, zones: list)
        #expect(gate.isOpen(binID: list[1].binID))
        #expect(!gate.isOpen(binID: list[0].binID))
    }

    @Test("The snapshot routes the gate to whichever detector is selected")
    func snapshotRoutesToSelectedSource() {
        let detector = BinMarkerStateDetector()
        let list = zones(3)
        detector.ingest(
            detections: [detection(slot: 1, at: list[1].centroid, timestamp: 100)],
            timestamp: 100
        )
        let markerFrame = detector.update(zones: list, timestamp: 100)

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
