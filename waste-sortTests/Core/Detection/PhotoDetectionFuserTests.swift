import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

/// Pins the photo ensemble contract: agreeing passes decide, disagreement falls back
/// to the residual stream instead of a coin-flip argmax, and singletons survive alone.
struct PhotoDetectionFuserTests {
    private func input(
        key: String,
        conf: Float,
        x: CGFloat = 0.4,
        size: CGFloat = 0.2
    ) -> PhotoPassInput {
        PhotoPassInput(
            rawClassKey: key,
            conf: conf,
            rectNorm: CGRect(x: x - size / 2, y: 0.4 - size / 2, width: size, height: size)
        )
    }

    @Test("agreeing passes decide confidently")
    func agreementDecides() {
        let verdicts = PhotoDetectionFuser.fuseCore(passes: [
            [input(key: "organic", conf: 0.9)],
            [input(key: "organic", conf: 0.85)]
        ])

        #expect(verdicts.count == 1)
        #expect(verdicts[0].classKey == "organic")
        #expect(!verdicts[0].wasUncertain)
    }

    @Test("disagreeing passes fall back to residual as unsure")
    func disagreementFallsBack() {
        let verdicts = PhotoDetectionFuser.fuseCore(passes: [
            [input(key: "clean_inorganic", conf: 0.9)],
            [input(key: "residual", conf: 0.9)]
        ])

        #expect(verdicts.count == 1)
        #expect(verdicts[0].classKey == BinGuide.residual.id)
        #expect(verdicts[0].wasUncertain)
    }

    @Test("weak challenger keeps the leader decisive")
    func weakChallengerKeepsLeader() {
        let verdicts = PhotoDetectionFuser.fuseCore(passes: [
            [input(key: "organic", conf: 0.95)],
            [input(key: "residual", conf: 0.42)]
        ])

        #expect(verdicts.count == 1)
        #expect(verdicts[0].classKey == "organic")
        #expect(!verdicts[0].wasUncertain)
    }

    @Test("unmatched boxes in later passes become their own detections")
    func unmatchedSpawnsNewGroup() {
        let verdicts = PhotoDetectionFuser.fuseCore(passes: [
            [input(key: "organic", conf: 0.9, x: 0.2)],
            [
                input(key: "organic", conf: 0.85, x: 0.2),
                input(key: "clean_inorganic", conf: 0.8, x: 0.8)
            ]
        ])

        #expect(verdicts.count == 2)
        #expect(Set(verdicts.map(\.classKey)) == ["organic", "clean_inorganic"])
        #expect(verdicts.allSatisfy { !$0.wasUncertain })
    }

    @Test("empty pass list yields no detections")
    func emptyPasses() {
        #expect(PhotoDetectionFuser.fuseCore(passes: []).isEmpty)
    }
}
