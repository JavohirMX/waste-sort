import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

/// The routing contract: unsure items are advised toward the residual stream, sure
/// items toward their own bin. CTA arrows, the HUD category bar, and deposit scoring
/// all read this through `advisedBinID`.
struct AdvisedBinRoutingTests {
    private func track(
        classKey: String,
        beliefUncertain: Bool
    ) -> TrackedDetection {
        TrackedDetection(
            id: 1,
            classKey: classKey,
            className: classKey,
            conf: 0.9,
            displayXywhn: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1),
            beliefUncertain: beliefUncertain
        )
    }

    @Test("certain tracks advise their own bin")
    func certainRoutesToOwnBin() {
        #expect(track(classKey: "organic", beliefUncertain: false).advisedBinID == "organic")
        #expect(track(classKey: "residual", beliefUncertain: false).advisedBinID == "residual")
        #expect(track(classKey: "clean_inorganic", beliefUncertain: false).advisedBinID == "clean_inorganic")
    }

    @Test("uncertain tracks always advise residual regardless of label")
    func uncertainAlwaysRoutesToFallback() {
        for key in ["organic", "residual", "clean_inorganic"] {
            #expect(
                track(classKey: key, beliefUncertain: true).advisedBinID == BinGuide.fallbackBinID
            )
        }
    }

    @Test("fallback bin is the residual stream")
    func fallbackIsResidual() {
        #expect(BinGuide.fallbackBinID == BinGuide.residual.id)
    }

    @Test("CTA cue mapper routes uncertain tracks to the fallback bin")
    func cueMapperUsesAdvice() {
        let cues = CTACueMapper.cues(
            from: [track(classKey: "organic", beliefUncertain: true)],
            imageSize: CGSize(width: 1000, height: 1000),
            viewSize: CGSize(width: 500, height: 500),
            rotation: .zero,
            mirror: false
        )
        #expect(cues.count == 1)
        #expect(cues.first?.binID == BinGuide.residual.id)
    }
}
