import SwiftUI
import UIKit

// MARK: - PCC judge passes (deposit trigger + verdict-audit trigger)

extension LiveCameraCoordinator {
    /// Both judge passes for one frame — the deposit trigger and the
    /// verdict-audit trigger — behind the single settings gate.
    func runPCCPasses(
        zoneFrame: ZoneFrameResult,
        tracked: [TrackedDetection],
        confirmationFrame: ConfirmationFrame,
        originalImage: UIImage?,
        settings: RuntimeSettings
    ) {
        guard settings.pccJudgeEnabled else { return }
        evaluatePCCJudgments(
            deposits: zoneFrame.deposits,
            tracked: tracked,
            confirmationFrame: confirmationFrame,
            originalImage: originalImage,
            pipeline: settings.decisionPipeline,
            confidentAuditEnabled: settings.pccConfidentAuditEnabled
        )
        auditYOLOVerdicts(
            tracked: tracked,
            originalImage: originalImage,
            pipeline: settings.decisionPipeline
        )
    }

    /// The "judge every YOLO prediction" path: once an item has been tracked for a
    /// few consecutive frames, its crop plus YOLO's claim go to the judge —
    /// confident or not, thrown or not. One judgment per track id: the deposit
    /// path's `hasRequested` guard sees audit requests, so a scored item is never
    /// double-judged. Runs on the inference queue; the queue owns the pacing.
    private func auditYOLOVerdicts(
        tracked: [TrackedDetection],
        originalImage: UIImage?,
        pipeline: DecisionPipeline
    ) {
        let liveIds = Set(tracked.map(\.id))
        verdictAuditFrames = verdictAuditFrames.filter { liveIds.contains($0.key) }
        guard let frameCG = originalImage.flatMap(UprightFrameImage.cgImage(from:)) else { return }
        for track in tracked {
            let frames = (verdictAuditFrames[track.id] ?? 0) + 1
            verdictAuditFrames[track.id] = frames
            switch PCCVerdictAuditPolicy.decision(
                framesSeen: frames,
                pccEnabled: true,
                alreadyRequested: pccJudge.hasRequested(trackId: track.id)
            ) {
            case .skip:
                continue
            case .trigger:
                let crop = ItemCropper.crop(
                    frameCG,
                    to: track.displayXywhn,
                    padding: WasteSortConfig.defaultPCCCropPadding,
                    maximumSide: WasteSortConfig.defaultPCCCropMaximumSide,
                    minimumSide: WasteSortConfig.defaultPCCCropMinimumPixels
                )
                pccQueue.enqueue(
                    ArbiterRequestContext(
                        trackId: track.id,
                        sessionId: nil,
                        yoloLabel: track.classKey,
                        yoloConfidence: Double(track.conf),
                        beliefUncertain: false,
                        beliefMargin: 1,
                        engineBinID: BinGuide.info(for: track.classKey).id,
                        pipeline: String(describing: pipeline),
                        triggeredAt: Date()
                    ),
                    crop: crop
                )
            }
        }
    }

    /// Silent second opinions: one arbitration per uncertain→residual deposit.
    /// Runs on the inference queue but only does real work when a deposit just
    /// settled, and everything heavy rides detached tasks inside the arbiter.
    private func evaluatePCCJudgments(
        deposits: [ZoneDeposit],
        tracked: [TrackedDetection],
        confirmationFrame: ConfirmationFrame,
        originalImage: UIImage?,
        pipeline: DecisionPipeline,
        confidentAuditEnabled: Bool
    ) {
        guard !deposits.isEmpty else { return }
        var cropsByTrack: [Int: CGImage] = [:]
        if let frameCG = originalImage.flatMap(UprightFrameImage.cgImage(from:)) {
            for deposit in deposits {
                guard let track = tracked.first(where: { $0.id == deposit.trackID }) else { continue }
                cropsByTrack[deposit.trackID] = ItemCropper.crop(
                    frameCG,
                    to: track.displayXywhn,
                    padding: WasteSortConfig.defaultPCCCropPadding,
                    maximumSide: WasteSortConfig.defaultPCCCropMaximumSide,
                    minimumSide: WasteSortConfig.defaultPCCCropMinimumPixels
                )
            }
        }
        let status = pccJudge.currentStatus()
        // Spec 003: iterate ALL deposits, uncertain first (stable). The
        // primary path is served before audits, so daily quota
        // starvation can only ever hit audits — never uncertain judging.
        let orderedDeposits = deposits.enumerated().sorted { lhs, rhs in
            let lhsRank = lhs.element.wasUncertain ? 0 : 1
            let rhsRank = rhs.element.wasUncertain ? 0 : 1
            return (lhsRank, lhs.offset) < (rhsRank, rhs.offset)
        }
        for (_, deposit) in orderedDeposits {
            guard let track = tracked.first(where: { $0.id == deposit.trackID }) else { continue }
            let context = ArbiterRequestContext(
                trackId: deposit.trackID,
                sessionId: nil,
                yoloLabel: deposit.modelTopClassKey,
                yoloConfidence: Double(deposit.conf),
                beliefUncertain: deposit.wasUncertain,
                beliefMargin: Double(deposit.margin),
                engineBinID: deposit.classKey,
                pipeline: String(describing: pipeline),
                triggeredAt: Date()
            )
            let policyInputs = PCCTriggerPolicy.Inputs(
                wasUncertainFallback: deposit.wasUncertain,
                confirmationLocked: confirmationFrame.state(for: deposit.trackID) == .confirmed,
                confidentAuditEnabled: confidentAuditEnabled,
                judgeEnabled: true,
                availabilityIsReady: status.availability.isReady,
                quotaLimited: !status.isUsable && status.availability.isReady,
                breakerOpen: status.breakerOpenUntil.map { $0 > Date() } ?? false,
                alreadyRequested: pccJudge.hasRequested(trackId: deposit.trackID)
            )
            switch PCCTriggerPolicy.decision(for: policyInputs) {
            case .trigger:
                pccQueue.enqueue(context, crop: cropsByTrack[deposit.trackID])
            case .skip(let reason):
                guard reason != .notUncertainFallback else { continue }
                pccJudge.recordSkip(
                    context,
                    reasonSkipOutcome: Self.outcome(for: reason, availability: status.availability)
                )
            }
        }
    }

    private static func outcome(
        for reason: PCCTriggerPolicy.SkipReason,
        availability: PCCJudgeAvailability
    ) -> PCCVerdictRecord.Outcome {
        switch reason {
        case .disabled: return .skippedDisabled
        case .quotaLimited: return .skippedQuota
        case .breakerOpen, .alreadyRequested: return .error("gate: \(String(describing: reason))")
        case .confirmationLocked, .notUncertainFallback:
            return .skippedUnavailable("superseded")
        case .unavailable(let detail):
            return .skippedUnavailable(detail.isEmpty ? availability.summary : detail)
        }
    }
}
