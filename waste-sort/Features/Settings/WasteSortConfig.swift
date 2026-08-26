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
    static let defaultDemoMode = false
}

/// Snapshot of tunable inference and tracking values, passed into Live camera updates.
struct RuntimeSettings: Equatable {
    var confidence: Double
    var iou: Double
    var maxItems: Int
    var decisionPipeline: DecisionPipeline
    var barcodeAssistEnabled: Bool
    var appearanceAssistEnabled: Bool
    var recheckAssistEnabled: Bool
    var verboseDetectionLogging: Bool
    var confirmHits: Int
    var maxMisses: Int
    var trackerIou: Double
    var crossClassIou: Double
    var beliefThreshold: Double
    var beliefMargin: Double
    var emaAlpha: Double
    var boxInflate: Double
    var maxSpeed: Double
    var preferredCameraID: String
    var selectedModelName: String
    var liveRotation: LivePreviewRotation
    var liveMirror: Bool
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var exposureLocked: Bool
    var focusLocked: Bool
    var whiteBalanceLocked: Bool

    var captureControls: CameraCaptureControls {
        CameraCaptureControls(
            exposureLocked: exposureLocked,
            focusLocked: focusLocked,
            whiteBalanceLocked: whiteBalanceLocked
        )
    }

    var frameColor: FrameColorControls {
        FrameColorControls(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation
        )
    }
}
