import CoreGraphics
import Foundation
import UltralyticsYOLO

/// One fused photo detection: where the box is, what the ensemble concluded, and how
/// sure it is allowed to sound about that.
nonisolated struct FusedPhotoDetection: Sendable {
    let box: Box
    /// Ensemble-backed label, or `BinGuide.fallbackBinID` when unsure — mirrors the
    /// live pipeline so advice and scoring stay consistent across surfaces.
    let classKey: String
    let className: String
    let conf: Float
    let margin: Float
    let wasUncertain: Bool
}

/// Pass-agnostic detection input so the fusion logic stays unit-testable without
/// constructing package types (their memberwise initializers are internal).
nonisolated struct PhotoPassInput: Equatable, Sendable {
    let rawClassKey: String
    let conf: Float
    let rectNorm: CGRect
}

/// A fused ensemble verdict over one anchor region.
nonisolated struct FusedPhotoVerdict: Equatable, Sendable {
    let classKey: String
    let className: String
    let conf: Float
    let margin: Float
    let wasUncertain: Bool
}

/// Fuses multi-pass photo inference (original + horizontal flip) into single verdicts
/// through the same `BeliefEngine` gates as the live camera.
///
/// A photo has no timeline, so instead of temporal voting the ensemble supplies the
/// second observation: every pass is one evidence event for its best-matching region,
/// plus the color/texture prior sampled inside it. Two agreeing passes decide;
/// disagreement lands in the residual fallback rather than a coin-flip argmax.
nonisolated enum PhotoDetectionFuser {
    static func fuse(
        passes: [[Box]],
        priors: [AppearancePrior?] = [],
        threshold: Double = WasteSortConfig.defaultBeliefThreshold,
        margin: Double = WasteSortConfig.defaultBeliefMargin,
        appearanceWeight: Double = WasteSortConfig.defaultAppearanceWeight
    ) -> [FusedPhotoDetection] {
        guard let primary = passes.first else { return [] }
        let anchors = primary.sorted { $0.conf > $1.conf }
        let inputs = passes.map { pass in
            pass.map { box in
                PhotoPassInput(
                    rawClassKey: BinGuide.normalizedKey(box.cls),
                    conf: box.conf,
                    rectNorm: box.xywhn
                )
            }
        }
        let verdicts = fuseCore(
            passes: inputs,
            priors: priors,
            threshold: threshold,
            margin: margin,
            appearanceWeight: appearanceWeight
        )
        guard verdicts.count == anchors.count else { return [] }
        return zip(verdicts, anchors).map { verdict, anchor in
            FusedPhotoDetection(
                box: anchor,
                classKey: verdict.classKey,
                className: verdict.className,
                conf: verdict.conf,
                margin: verdict.margin,
                wasUncertain: verdict.wasUncertain
            )
        }
    }

    /// The testable core: same-region evidence from every pass collapses into one
    /// verdict per first-pass region; later-only regions become their own verdicts.
    static func fuseCore(
        passes: [[PhotoPassInput]],
        priors: [AppearancePrior?] = [],
        threshold: Double = WasteSortConfig.defaultBeliefThreshold,
        margin: Double = WasteSortConfig.defaultBeliefMargin,
        appearanceWeight: Double = WasteSortConfig.defaultAppearanceWeight
    ) -> [FusedPhotoVerdict] {
        guard let primary = passes.first else { return [] }
        var consumed = Array(repeating: false, count: passes.count)

        var groups: [(input: PhotoPassInput, belief: BeliefEngine)] = []
        // Highest-confidence anchors first so each group claims its region honestly.
        for input in primary.sorted(by: { $0.conf > $1.conf }) {
            let belief = makeEngine(threshold: threshold, margin: margin, passes: passes.count)
            belief.observe(classKey: input.rawClassKey, className: input.rawClassKey, conf: input.conf, at: 0)
            if let prior = priors[safe: groups.count] ?? nil {
                inject(prior: prior, weight: appearanceWeight, into: belief)
            }
            groups.append((input: input, belief: belief))
        }

        for passIndex in passes.indices.dropFirst() {
            consumed[passIndex] = true
            for input in passes[passIndex] {
                if let index = bestGroup(for: input, in: groups) {
                    groups[index].belief.observe(
                        classKey: input.rawClassKey,
                        className: input.rawClassKey,
                        conf: input.conf,
                        at: CFAbsoluteTime(passIndex)
                    )
                } else {
                    let belief = makeEngine(threshold: threshold, margin: margin, passes: passes.count)
                    belief.observe(
                        classKey: input.rawClassKey,
                        className: input.rawClassKey,
                        conf: input.conf,
                        at: 0
                    )
                    groups.append((input: input, belief: belief))
                }
            }
        }

        return groups.map { group in
            let state = group.belief.currentState(at: CFAbsoluteTime(passes.count))
            // A region only one pass ever saw has nothing to fuse — fall back to the
            // plain single-read semantics the photo screen always had, rather than
            // flagging honest detections as unsure just because they were easy.
            guard state.evidenceEvents >= max(passes.count, 2) else {
                return FusedPhotoVerdict(
                    classKey: group.input.rawClassKey,
                    className: group.input.rawClassKey,
                    conf: group.input.conf,
                    margin: 1,
                    wasUncertain: false
                )
            }
            if state.isDecided {
                return FusedPhotoVerdict(
                    classKey: state.topKey,
                    className: group.input.rawClassKey,
                    conf: Float(state.probabilities[state.topKey] ?? 0),
                    margin: Float(state.margin),
                    wasUncertain: false
                )
            }
            return FusedPhotoVerdict(
                classKey: BinGuide.fallbackBinID,
                className: BinGuide.bin(id: BinGuide.fallbackBinID).title,
                conf: Float(state.probabilities[state.topKey] ?? 0),
                margin: Float(state.margin),
                wasUncertain: true
            )
        }
    }

    private static func makeEngine(threshold: Double, margin: Double, passes: Int) -> BeliefEngine {
        BeliefEngine(config: BeliefConfig(
            // Photos are frozen instants: no recency weighting wanted, the huge
            // half-life makes pass order irrelevant while reusing the same gates.
            halfLife: 10_000,
            decideThreshold: threshold,
            decideMargin: margin,
            switchConfirmations: 1,
            minEvidenceEvents: max(passes, 2)
        ))
    }

    private static func inject(prior: AppearancePrior, weight: Double, into belief: BeliefEngine) {
        for (key, share) in prior.shares {
            belief.inject(
                classKey: key,
                className: key,
                weight: share * weight,
                at: 0,
                countsAsEvidence: false
            )
        }
    }

    private static func bestGroup(
        for input: PhotoPassInput,
        in groups: [(input: PhotoPassInput, belief: BeliefEngine)]
    ) -> Int? {
        var bestIndex: Int?
        var bestIoU: CGFloat = 0
        for (index, group) in groups.enumerated() {
            let value = iou(group.input.rectNorm, input.rectNorm)
            if value >= 0.5, value > bestIoU {
                bestIoU = value
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return interArea / union
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
