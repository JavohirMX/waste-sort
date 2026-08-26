import Combine
import Foundation
enum WasteSortConfig {
    static let defaultConfidence = 0.4
    static let defaultIou = 0.7
    static let defaultMaxItems = 100

    static let defaultConfirmHits = 2
    static let defaultMaxMisses = 3
    static let defaultTrackerIou = 0.3
    static let defaultCrossClassIou = 0.30
    /// Belief-engine verdict gate for both the overlay label and the deposit scoring.
    static let defaultBeliefThreshold = 0.55
    static let defaultBeliefMargin = 0.15
    /// Overlay policy: short memory so labels track the item currently in hand.
    static let defaultBeliefDisplayHalfLife = 0.80
    /// Deposit policy: near-lifetime memory so a throw is scored on everything seen.
    static let defaultBeliefDepositHalfLife = 4.0
    static let defaultBeliefSwitchConfirmations = 2
    static let defaultBeliefMinEvidenceEvents = 2
    static let defaultBeliefMinEvidenceDepositEvents = 3
    /// Color/texture prior fused into beliefs when the camera frame is available.
    static let defaultAppearanceAssistEnabled = true
    static let defaultAppearanceWeight = 0.35
    /// Minimum wall-clock seconds between appearance samples (per pipeline, all boxes).
    static let defaultAppearanceInterval = 0.25
    /// Crop-and-recheck escalation for unsure items.
    static let defaultRecheckAssistEnabled = true
    // MARK: PCC uncertainty judge (specs/001-pcc-uncertainty-judge)
    /// Silent second opinions default on: every uncertain deposit becomes data.
    static let defaultPCCJudgeEnabled = true
    /// Spec 003: PCC also double-checks CONFIDENT verdicts (log-only).
    /// Uncertain deposits keep first priority, so quota starvation can only
    /// ever hit audits — never the primary path.
    static let defaultPCCConfidentAuditEnabled = true
    static let defaultPCCReasoningLevel = "moderate"
    /// Wall-clock budget for one cloud arbitration.
    /// 20 s: measured PCC vision latency on real photos (iOS 27 sim) was 1.3 s
    /// at the production 448 px crop but 6–8 s at 1024 px with one timeout at
    /// 10 s. The judge is silent and background, so headroom is free.
    static let defaultPCCTimeoutSeconds = 20.0
    /// Consecutive failed arbitrations before the circuit breaker opens.
    static let defaultPCCBreakerThreshold = 3
    /// How long the breaker stays open after tripping.
    static let defaultPCCBreakerCooldownSeconds = 120.0
    /// Judgment queue depth. Deep by design: entries are one 448 px crop each
    /// and quota-holding means a busy day drains tonight instead of dying as skips.
    static let defaultPCCQueueCapacity = 200
    /// How long an entry may wait on *ambiguous* unavailability before it is
    /// recorded as skipped. Quota and breaker holds never expire against this.
    static let defaultPCCQueueEntryTTLSeconds = 120.0
    /// Recheck cadence while parked on ambiguous unavailability.
    static let defaultPCCQueueRetryPollSeconds = 15.0
    /// Wake cadence when quota is exhausted but no reset time was reported.
    static let defaultPCCQueueQuotaRetrySeconds = 60.0
    /// Records and crops older than this are pruned unless already exported.
    static let defaultPCCPruneDays = 30
    static let defaultPCCCropPadding: CGFloat = 0.15
    static let defaultPCCCropMaximumSide = 448
    static let defaultPCCCropMinimumPixels = 96
    /// Learned-correction thresholds (specs/002). Into-residual and lateral
    /// overrides need this many answered judgments with this dominance; pulling
    /// items out of residual needs the stricter `OutOfResidual` pair below.
    static let defaultPCCSuggestionMinSamples = 12
    static let defaultPCCSuggestionDominance = 0.75
    static let defaultPCCOutOfResidualMinSamples = 30
    static let defaultPCCOutOfResidualDominance = 0.85
    /// How long a track must stay unsure before the zoom pass fires.
    static let defaultRecheckDelay = 0.6
    /// Minimum seconds between re-checks of the same item.
    static let defaultRecheckCooldown = 2.0
    /// Multiplier on the re-check confidence when injected as belief evidence.
    static let defaultRecheckWeight = 1.5
    /// Which decision math produces bin advice. Belief is the production engine;
    /// legacy replays main's pre-belief math for A/B comparison.
    static let defaultDecisionPipeline = DecisionPipeline.belief
    /// Per-frame track events for offline decision-pipeline replays.
    /// Heavy but cheap enough at kiosk scale; on by default so sessions are always replayable.
    static let defaultVerboseDetectionLogging = true
    static let defaultEmaAlpha = 0.4
    static let defaultBoxInflate = 0.08
    static let defaultMaxSpeed = 0.8
    static let defaultModelName = WasteSortModel.bestv36.resourceName
    static let defaultLiveRotation = LivePreviewRotation.zero
    static let defaultLiveMirror = false
    static let defaultShowConfidence = false
    static let defaultShowBoxIcon = true
    static let defaultShowBoxCategory = false
    static let defaultBoxLabelPlacement = BoxLabelPlacement.topTrailing
    static let defaultBoxBadgeScale = 1.0
    static let defaultHUDTextScale = 1.0
    static let defaultShowZoneOverlay = true
    static let defaultCTAStyle = CTAStyle.arrows
    static let defaultBrightness = 0.0
    static let defaultContrast = 1.0
    static let defaultSaturation = 1.0
    static let defaultExposureLocked = false
    static let defaultFocusLocked = false
    static let defaultWhiteBalanceLocked = false
    static let defaultAutoRecordOnOpen = false
    static let defaultShowFPS = false
    static let defaultUseMockStats = true
    static let defaultVoiceGuidanceEnabled = false
    static let defaultBarcodeAssistEnabled = true
    static let defaultHasCompletedOnboarding = false
    static let defaultFoundationConfirmation = false
    static let defaultFoundationVerdictLog = false
    static let defaultShowLastDepositOnLive = false
    static let defaultThrowFeedbackSounds = true
}

