import CoreGraphics
import Foundation
import Testing

@testable import waste_sort

@Suite("FrameBinOpenState")
struct FrameBinOpenStateTests {
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

    @Test("empty AprilTag frame reads every bin as not open (fail-closed)")
    func emptyFrameIsNotOpen() {
        let state = FrameBinOpenState(tagFrame: AprilTagStatusFrame(), zones: zones)
        #expect(!state.isOpen(binID: BinGuide.organic.id))
        #expect(!state.isOpen(binID: BinGuide.residual.id))
    }

    @Test("only a positively open zone maps onto an open bin id")
    func openZoneOpensBin() {
        let frame = AprilTagStatusFrame(statuses: [
            organicZone.id: BinOpenness(state: .closed, confidence: 0.98),
            residualZone.id: BinOpenness(state: .open, confidence: 0.98)
        ])
        let state = FrameBinOpenState(tagFrame: frame, zones: zones)
        #expect(!state.isOpen(binID: BinGuide.organic.id))
        #expect(state.isOpen(binID: BinGuide.residual.id))
    }

    @Test("unknown lid state is not open")
    func unknownIsNotOpen() {
        let frame = AprilTagStatusFrame(statuses: [
            organicZone.id: BinOpenness(state: .unknown)
        ])
        let state = FrameBinOpenState(tagFrame: frame, zones: zones)
        #expect(!state.isOpen(binID: BinGuide.organic.id))
    }
}
