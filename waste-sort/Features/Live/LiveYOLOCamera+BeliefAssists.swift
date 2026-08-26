import SwiftUI
import UIKit
import UltralyticsYOLO

// MARK: - Belief-assist layers (appearance priors + zoom re-checks)

extension LiveCameraCoordinator {
    /// Samples color/texture priors for the largest boxes at most once per interval.
    /// Runs on the inference queue; the sampler is queue-owned state.
    func sampleAppearancePriors(
        image: UIImage,
        boxes: [Box]
    ) -> [Int: AppearancePrior] {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAppearanceSampleAt >= WasteSortConfig.defaultAppearanceInterval else {
            return [:]
        }
        lastAppearanceSampleAt = now
        // Bound the cost: the biggest items are the ones being sorted.
        let largest = boxes.sorted { $0.xywhn.width * $0.xywhn.height > $1.xywhn.width * $1.xywhn.height }
            .prefix(6)
        var priors: [Int: AppearancePrior] = [:]
        for box in largest {
            guard let prior = appearanceSampler
                .sample(image: image, rectNorm: box.xywhn)
                .map({ AppearanceAnalyzer.prior(for: $0) })
            else { continue }
            priors[box.index] = prior
        }
        return priors
    }

    /// Fires zoom re-checks for tracks that have been unsure and still for long
    /// enough. Inference-queue owned state; completion lands on the engine's queue.
    func requestRechecks(
        for tracked: [TrackedDetection],
        image: UIImage,
        settings: RuntimeSettings
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        for track in tracked where track.beliefUncertain {
            guard zoomRecheck.shouldRecheck(
                track: track,
                timestamp: now,
                delay: WasteSortConfig.defaultRecheckDelay,
                cooldown: WasteSortConfig.defaultRecheckCooldown,
                maxDriftPerFrame: 0.05
            ) else { continue }
            zoomRecheck.request(
                image: image,
                boxNorm: track.displayXywhn,
                trackID: track.id,
                modelName: settings.selectedModelName,
                settings: settings
            ) { [weak self] outcome in
                guard let self, let outcome else { return }
                self.recheckBufferLock.lock()
                self.pendingRecheckOutcomes.append(outcome)
                self.recheckBufferLock.unlock()
            }
        }
    }

    /// Applies buffered re-check verdicts to the tracker. Must run on the inference
    /// queue — this is why outcomes buffer instead of injecting directly.
    func drainRecheckOutcomes() {
        recheckBufferLock.lock()
        let outcomes = pendingRecheckOutcomes
        pendingRecheckOutcomes.removeAll(keepingCapacity: true)
        recheckBufferLock.unlock()
        guard !outcomes.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        for outcome in outcomes {
            tracker.injectRecheck(
                trackID: outcome.trackID,
                classKey: outcome.classKey,
                className: outcome.className,
                conf: outcome.conf,
                weight: Float(WasteSortConfig.defaultRecheckWeight) * outcome.conf,
                at: now
            )
        }
    }
}
