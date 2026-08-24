import CoreGraphics
import Foundation
import Testing
@testable import waste_sort

@Suite("Legacy decision pipeline at runtime")
struct LegacyPipelineRuntimeTests {
    private func detection(
        classKey: String,
        conf: Float,
        x: CGFloat,
        timestamp: CFAbsoluteTime = 0
    ) -> RawDetection {
        RawDetection(
            classKey: classKey,
            className: classKey,
            conf: conf,
            xywhn: CGRect(x: x, y: 0.4, width: 0.2, height: 0.2),
            appearancePrior: nil
        )
    }

    @Test("legacy tracks never report uncertainty, even mid coin-flip")
    func neverUncertain() {
        let tracker = DetectionTracker()
        tracker.pipeline = .legacy
        tracker.confirmHits = 1

        // Interleave two classes on the same box — the exact situation where the
        // belief engine would flag "not sure".
        var t = 0.0
        var emitted: [TrackedDetection] = []
        for i in 0..<12 {
            let key = i.isMultiple(of: 2) ? BinGuide.cleanInorganic.id : BinGuide.residual.id
            emitted = tracker.update(
                [detection(classKey: key, conf: 0.9, x: 0.4)],
                timestamp: t
            )
            t += 0.033
        }

        #expect(!emitted.isEmpty)
        #expect(emitted.allSatisfy { !$0.beliefUncertain })
    }

    @Test("belief pipeline still flags the same stream as uncertain")
    func beliefStillFlags() {
        let tracker = DetectionTracker()
        tracker.confirmHits = 1

        var t = 0.0
        var emitted: [TrackedDetection] = []
        for i in 0..<12 {
            let key = i.isMultiple(of: 2) ? BinGuide.cleanInorganic.id : BinGuide.residual.id
            emitted = tracker.update(
                [detection(classKey: key, conf: 0.9, x: 0.4)],
                timestamp: t
            )
            t += 0.033
        }

        #expect(!emitted.isEmpty)
        #expect(emitted.contains { $0.beliefUncertain })
    }

    @Test("window vote flips the label once the gate opens")
    func windowVoteFlipsLabel() {
        // Faithful-to-main subtlety: the sample buffer is pruned to [now − window, now]
        // BEFORE the span check demands `last − first ≥ window`, so the vote only fires
        // when the oldest surviving sample lands on the cutoff — which regular
        // `i * 0.05` grids hit (frame 19 here) but drifted accumulation never does.
        var engine = LegacyDecisionEngine()
        var label = ""
        for i in 0..<30 {
            let key = i < 15 ? BinGuide.organic.id : BinGuide.residual.id
            engine.observe(
                classKey: key,
                className: key,
                conf: 0.95,
                at: CFAbsoluteTime(i) * 0.05
            )
            label = engine.label
            if i < 19 {
                #expect(label == BinGuide.organic.id, "frame \(i)")
            } else {
                #expect(label == BinGuide.residual.id, "frame \(i)")
            }
        }
        #expect(engine.verdict().classKey == BinGuide.residual.id)
    }

    @Test("drifted timestamps keep a confirmed label stuck, exactly like main in production")
    func confirmedTrackResistsChallenger() {
        let tracker = DetectionTracker()
        tracker.pipeline = .legacy
        tracker.confirmHits = 1

        var t = 0.0
        var sawFlip = false
        for i in 0..<30 {
            let key = i < 15 ? BinGuide.organic.id : BinGuide.residual.id
            let tracked = tracker.update(
                [detection(classKey: key, conf: 0.95, x: 0.4)],
                timestamp: t
            )
            t += 0.05
            if tracked.contains(where: { $0.classKey == BinGuide.residual.id }) {
                sawFlip = true
            }
        }

        // Not a bug in the toggle: accumulated wall-clock drift means the pruned span
        // never reaches the window on real 30 fps frames, so main's confirmed labels
        // stuck too — relabels reached users through track respawns and confirmation,
        // both preserved unchanged. This quirk is why the bake-off scores verdicts.
        #expect(!sawFlip)
    }
}
