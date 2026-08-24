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
    static let defaultModelName = WasteSortModel.bestv35.resourceName
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

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var confidence: Double {
        didSet { persist(confidence, key: Keys.confidence) }
    }
    @Published var iou: Double {
        didSet { persist(iou, key: Keys.iou) }
    }
    @Published var maxItems: Int {
        didSet { persist(maxItems, key: Keys.maxItems) }
    }
    @Published var confirmHits: Int {
        didSet { persist(confirmHits, key: Keys.confirmHits) }
    }
    @Published var maxMisses: Int {
        didSet { persist(maxMisses, key: Keys.maxMisses) }
    }
    @Published var trackerIou: Double {
        didSet { persist(trackerIou, key: Keys.trackerIou) }
    }
    @Published var crossClassIou: Double {
        didSet { persist(crossClassIou, key: Keys.crossClassIou) }
    }
    /// Belief-engine gate: probability the top class must reach for a confident verdict.
    @Published var beliefThreshold: Double {
        didSet { persist(beliefThreshold, key: Keys.beliefThreshold) }
    }
    /// Belief-engine gate: required lead of the top class over the runner-up.
    @Published var beliefMargin: Double {
        didSet { persist(beliefMargin, key: Keys.beliefMargin) }
    }
    @Published var emaAlpha: Double {
        didSet { persist(emaAlpha, key: Keys.emaAlpha) }
    }
    @Published var boxInflate: Double {
        didSet { persist(boxInflate, key: Keys.boxInflate) }
    }
    @Published var maxSpeed: Double {
        didSet { persist(maxSpeed, key: Keys.maxSpeed) }
    }
    /// `CameraPreference.autoID` or an `AVCaptureDevice.uniqueID`.
    @Published var preferredCameraID: String {
        didSet { persist(preferredCameraID, key: Keys.preferredCameraID) }
    }
    /// Bundle resource name: `best`, `bestv3.2`, `bestv3.3`, `bestv3.4`, or `bestv3.5`.
    @Published var selectedModelName: String {
        didSet { persist(selectedModelName, key: Keys.selectedModelName) }
    }
    @Published var liveRotation: LivePreviewRotation {
        didSet { persist(liveRotation.rawValue, key: Keys.liveRotation) }
    }
    @Published var liveMirror: Bool {
        didSet { persist(liveMirror, key: Keys.liveMirror) }
    }
    @Published var showConfidence: Bool {
        didSet { persist(showConfidence, key: Keys.showConfidence) }
    }
    @Published var showBoxIcon: Bool {
        didSet { persist(showBoxIcon, key: Keys.showBoxIcon) }
    }
    @Published var showBoxCategory: Bool {
        didSet { persist(showBoxCategory, key: Keys.showBoxCategory) }
    }
    @Published var boxLabelPlacement: BoxLabelPlacement {
        didSet { persist(boxLabelPlacement.rawValue, key: Keys.boxLabelPlacement) }
    }
    @Published var boxBadgeScale: Double {
        didSet { persist(boxBadgeScale, key: Keys.boxBadgeScale) }
    }
    @Published var hudTextScale: Double {
        didSet { persist(hudTextScale, key: Keys.hudTextScale) }
    }
    @Published var showZoneOverlay: Bool {
        didSet { persist(showZoneOverlay, key: Keys.showZoneOverlay) }
    }
    @Published var ctaStyle: CTAStyle {
        didSet { persist(ctaStyle.rawValue, key: Keys.ctaStyle) }
    }
    @Published var brightness: Double {
        didSet { persist(brightness, key: Keys.brightness) }
    }
    @Published var contrast: Double {
        didSet { persist(contrast, key: Keys.contrast) }
    }
    @Published var saturation: Double {
        didSet { persist(saturation, key: Keys.saturation) }
    }
    @Published var exposureLocked: Bool {
        didSet { persist(exposureLocked, key: Keys.exposureLocked) }
    }
    @Published var focusLocked: Bool {
        didSet { persist(focusLocked, key: Keys.focusLocked) }
    }
    @Published var whiteBalanceLocked: Bool {
        didSet { persist(whiteBalanceLocked, key: Keys.whiteBalanceLocked) }
    }
    @Published var autoRecordOnOpen: Bool {
        didSet { persist(autoRecordOnOpen, key: Keys.autoRecordOnOpen) }
    }
    @Published var showFPS: Bool {
        didSet { persist(showFPS, key: Keys.showFPS) }
    }
    @Published var useMockStats: Bool {
        didSet { persist(useMockStats, key: Keys.useMockStats) }
    }
    /// Spoken deposit confirmations for hands-free kiosk operation.
    @Published var voiceGuidanceEnabled: Bool {
        didSet { persist(voiceGuidanceEnabled, key: Keys.voiceGuidanceEnabled) }
    }
    /// Throttled Vision pass surfacing product barcodes alongside YOLO results.
    @Published var barcodeAssistEnabled: Bool {
        didSet { persist(barcodeAssistEnabled, key: Keys.barcodeAssistEnabled) }
    }
    /// Soft color/texture prior fused into bin decisions when frames allow sampling.
    @Published var appearanceAssistEnabled: Bool {
        didSet { persist(appearanceAssistEnabled, key: Keys.appearanceAssistEnabled) }
    }
    /// Zoom-in second pass for items the engine cannot place confidently.
    @Published var recheckAssistEnabled: Bool {
        didSet { persist(recheckAssistEnabled, key: Keys.recheckAssistEnabled) }
    }
    /// Switches the bin-decision math without leaving the app: the belief engine
    /// versus main's pre-belief confidence vote. Assists (appearance prior, zoom
    /// re-check) only act on beliefs and go inert under legacy.
    @Published var decisionPipeline: DecisionPipeline {
        didSet { persist(decisionPipeline.rawValue, key: Keys.decisionPipeline) }
    }
    /// Emits one CSV event per tracked item per frame so sessions can be replayed
    /// through the offline decision bake-off (`Core/Evaluation`).
    @Published var verboseDetectionLogging: Bool {
        didSet { persist(verboseDetectionLogging, key: Keys.verboseDetectionLogging) }
    }
    /// Gates the first-launch onboarding flow. Intentionally left out of `resetToDefaults()`
    /// so restoring tuning values does not relaunch the tutorial — Settings offers a
    /// dedicated "Show onboarding again" action instead.
    @Published var hasCompletedOnboarding: Bool {
        didSet { persist(hasCompletedOnboarding, key: Keys.hasCompletedOnboarding) }
    }
    /// Ask the on-device Foundation model to confirm each item's category and lock it in.
    @Published var foundationConfirmationEnabled: Bool {
        didSet { persist(foundationConfirmationEnabled, key: Keys.foundationConfirmation) }
    }
    /// Show the model's raw answers on Live, including the ones that were not acted on.
    @Published var foundationVerdictLogEnabled: Bool {
        didSet { persist(foundationVerdictLogEnabled, key: Keys.foundationVerdictLog) }
    }
    /// Developer HUD: last-deposit chip on Live. Off by default — history lives in Stats.
    @Published var showLastDepositOnLive: Bool {
        didSet { persist(showLastDepositOnLive, key: Keys.showLastDepositOnLive) }
    }
    /// Play the correct / incorrect clip when a throw is scored. Visual feedback always plays.
    @Published var throwFeedbackSoundsEnabled: Bool {
        didSet { persist(throwFeedbackSoundsEnabled, key: Keys.throwFeedbackSounds) }
    }

    var selectedModel: WasteSortModel {
        WasteSortModel.from(resourceName: selectedModelName)
    }

    var boxOverlayStyle: BoxOverlayStyle {
        BoxOverlayStyle(
            showIcon: showBoxIcon,
            showCategory: showBoxCategory,
            showConfidence: showConfidence,
            placement: boxLabelPlacement,
            badgeScale: CGFloat(boxBadgeScale)
        )
    }

    var runtime: RuntimeSettings {
        RuntimeSettings(
            confidence: confidence,
            iou: iou,
            maxItems: maxItems,
            decisionPipeline: decisionPipeline,
            barcodeAssistEnabled: barcodeAssistEnabled,
            appearanceAssistEnabled: appearanceAssistEnabled,
            recheckAssistEnabled: recheckAssistEnabled,
            verboseDetectionLogging: verboseDetectionLogging,
            confirmHits: confirmHits,
            maxMisses: maxMisses,
            trackerIou: trackerIou,
            crossClassIou: crossClassIou,
            beliefThreshold: beliefThreshold,
            beliefMargin: beliefMargin,
            emaAlpha: emaAlpha,
            boxInflate: boxInflate,
            maxSpeed: maxSpeed,
            preferredCameraID: preferredCameraID,
            selectedModelName: selectedModelName,
            liveRotation: liveRotation,
            liveMirror: liveMirror,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            exposureLocked: exposureLocked,
            focusLocked: focusLocked,
            whiteBalanceLocked: whiteBalanceLocked
        )
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let confidence = "settings.confidence"
        static let iou = "settings.iou"
        static let maxItems = "settings.maxItems"
        static let confirmHits = "settings.confirmHits"
        /// v2 picks up shorter ghost lifetime without requiring a manual reset.
        static let maxMisses = "settings.maxMisses.v2"
        static let trackerIou = "settings.trackerIou"
        static let crossClassIou = "settings.crossClassIou"
        static let beliefThreshold = "settings.beliefThreshold"
        static let beliefMargin = "settings.beliefMargin"
        static let emaAlpha = "settings.emaAlpha"
        static let boxInflate = "settings.boxInflate"
        /// v2 picks up lower association speed without requiring a manual reset.
        static let maxSpeed = "settings.maxSpeed.v2"
        static let preferredCameraID = "settings.preferredCameraID"
        static let selectedModelName = "settings.selectedModelName"
        static let liveRotation = "settings.liveRotation"
        static let liveMirror = "settings.liveMirror"
        static let showConfidence = "settings.showConfidence"
        static let showBoxIcon = "settings.showBoxIcon"
        static let showBoxCategory = "settings.showBoxCategory"
        static let boxLabelPlacement = "settings.boxLabelPlacement"
        static let boxBadgeScale = "settings.boxBadgeScale"
        static let hudTextScale = "settings.hudTextScale"
        static let showZoneOverlay = "settings.showZoneOverlay"
        static let ctaStyle = "settings.ctaStyle"
        static let brightness = "settings.brightness"
        static let contrast = "settings.contrast"
        static let saturation = "settings.saturation"
        static let exposureLocked = "settings.exposureLocked"
        static let focusLocked = "settings.focusLocked"
        static let whiteBalanceLocked = "settings.whiteBalanceLocked"
        static let autoRecordOnOpen = "settings.autoRecordOnOpen"
        static let showFPS = "settings.showFPS"
        static let useMockStats = "settings.useMockStats"
        static let voiceGuidanceEnabled = "settings.voiceGuidanceEnabled"
        static let barcodeAssistEnabled = "settings.barcodeAssistEnabled"
        static let decisionPipeline = "settings.decisionPipeline"
        static let appearanceAssistEnabled = "settings.appearanceAssistEnabled"
        static let recheckAssistEnabled = "settings.recheckAssistEnabled"
        static let verboseDetectionLogging = "settings.verboseDetectionLogging"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        static let foundationConfirmation = "settings.foundationConfirmation"
        static let foundationVerdictLog = "settings.foundationVerdictLog"
        static let showLastDepositOnLive = "settings.showLastDepositOnLive"
        static let throwFeedbackSounds = "settings.throwFeedbackSounds"
    }

    /// Internal rather than private so tests can inject their own defaults suite,
    /// matching `AprilTagBindingStore`. Production code uses `AppSettings.shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        confidence = Self.loadDouble(defaults, Keys.confidence, WasteSortConfig.defaultConfidence)
        iou = Self.loadDouble(defaults, Keys.iou, WasteSortConfig.defaultIou)
        maxItems = Self.loadInt(defaults, Keys.maxItems, WasteSortConfig.defaultMaxItems)
        confirmHits = Self.loadInt(defaults, Keys.confirmHits, WasteSortConfig.defaultConfirmHits)
        maxMisses = Self.loadInt(defaults, Keys.maxMisses, WasteSortConfig.defaultMaxMisses)
        decisionPipeline = DecisionPipeline(
            rawValue: Self.loadString(defaults, Keys.decisionPipeline, WasteSortConfig.defaultDecisionPipeline.rawValue)
        ) ?? WasteSortConfig.defaultDecisionPipeline
        trackerIou = Self.loadDouble(defaults, Keys.trackerIou, WasteSortConfig.defaultTrackerIou)
        crossClassIou = Self.loadDouble(defaults, Keys.crossClassIou, WasteSortConfig.defaultCrossClassIou)
        beliefThreshold = Self.loadDouble(defaults, Keys.beliefThreshold, WasteSortConfig.defaultBeliefThreshold)
        beliefMargin = Self.loadDouble(defaults, Keys.beliefMargin, WasteSortConfig.defaultBeliefMargin)
        emaAlpha = Self.loadDouble(defaults, Keys.emaAlpha, WasteSortConfig.defaultEmaAlpha)
        boxInflate = Self.loadDouble(defaults, Keys.boxInflate, WasteSortConfig.defaultBoxInflate)
        maxSpeed = Self.loadDouble(defaults, Keys.maxSpeed, WasteSortConfig.defaultMaxSpeed)
        preferredCameraID = Self.loadString(
            defaults,
            Keys.preferredCameraID,
            CameraPreference.autoID
        )
        selectedModelName = Self.loadString(
            defaults,
            Keys.selectedModelName,
            WasteSortConfig.defaultModelName
        )
        liveRotation = LivePreviewRotation.from(
            degrees: Self.loadInt(defaults, Keys.liveRotation, WasteSortConfig.defaultLiveRotation.rawValue)
        )
        liveMirror = Self.loadBool(defaults, Keys.liveMirror, WasteSortConfig.defaultLiveMirror)
        showConfidence = Self.loadBool(defaults, Keys.showConfidence, WasteSortConfig.defaultShowConfidence)
        showBoxIcon = Self.loadBool(defaults, Keys.showBoxIcon, WasteSortConfig.defaultShowBoxIcon)
        showBoxCategory = Self.loadBool(
            defaults,
            Keys.showBoxCategory,
            WasteSortConfig.defaultShowBoxCategory
        )
        boxLabelPlacement = BoxLabelPlacement(
            rawValue: Self.loadString(
                defaults,
                Keys.boxLabelPlacement,
                WasteSortConfig.defaultBoxLabelPlacement.rawValue
            )
        ) ?? WasteSortConfig.defaultBoxLabelPlacement
        boxBadgeScale = Self.loadDouble(defaults, Keys.boxBadgeScale, WasteSortConfig.defaultBoxBadgeScale)
        hudTextScale = Self.loadDouble(defaults, Keys.hudTextScale, WasteSortConfig.defaultHUDTextScale)
        showZoneOverlay = Self.loadBool(
            defaults,
            Keys.showZoneOverlay,
            WasteSortConfig.defaultShowZoneOverlay
        )
        ctaStyle = CTAStyle(
            rawValue: Self.loadString(defaults, Keys.ctaStyle, WasteSortConfig.defaultCTAStyle.rawValue)
        ) ?? WasteSortConfig.defaultCTAStyle
        brightness = Self.loadDouble(defaults, Keys.brightness, WasteSortConfig.defaultBrightness)
        contrast = Self.loadDouble(defaults, Keys.contrast, WasteSortConfig.defaultContrast)
        saturation = Self.loadDouble(defaults, Keys.saturation, WasteSortConfig.defaultSaturation)
        exposureLocked = Self.loadBool(defaults, Keys.exposureLocked, WasteSortConfig.defaultExposureLocked)
        focusLocked = Self.loadBool(defaults, Keys.focusLocked, WasteSortConfig.defaultFocusLocked)
        whiteBalanceLocked = Self.loadBool(
            defaults,
            Keys.whiteBalanceLocked,
            WasteSortConfig.defaultWhiteBalanceLocked
        )
        autoRecordOnOpen = Self.loadBool(
            defaults,
            Keys.autoRecordOnOpen,
            WasteSortConfig.defaultAutoRecordOnOpen
        )
        showFPS = Self.loadBool(defaults, Keys.showFPS, WasteSortConfig.defaultShowFPS)
        useMockStats = Self.loadBool(defaults, Keys.useMockStats, WasteSortConfig.defaultUseMockStats)
        voiceGuidanceEnabled = Self.loadBool(defaults, Keys.voiceGuidanceEnabled, WasteSortConfig.defaultVoiceGuidanceEnabled)
        barcodeAssistEnabled = Self.loadBool(defaults, Keys.barcodeAssistEnabled, WasteSortConfig.defaultBarcodeAssistEnabled)
        appearanceAssistEnabled = Self.loadBool(defaults, Keys.appearanceAssistEnabled, WasteSortConfig.defaultAppearanceAssistEnabled)
        recheckAssistEnabled = Self.loadBool(defaults, Keys.recheckAssistEnabled, WasteSortConfig.defaultRecheckAssistEnabled)
        verboseDetectionLogging = Self.loadBool(defaults, Keys.verboseDetectionLogging, WasteSortConfig.defaultVerboseDetectionLogging)
        hasCompletedOnboarding = Self.loadBool(
            defaults,
            Keys.hasCompletedOnboarding,
            WasteSortConfig.defaultHasCompletedOnboarding
        )
        foundationConfirmationEnabled = Self.loadBool(
            defaults,
            Keys.foundationConfirmation,
            WasteSortConfig.defaultFoundationConfirmation
        )
        foundationVerdictLogEnabled = Self.loadBool(
            defaults,
            Keys.foundationVerdictLog,
            WasteSortConfig.defaultFoundationVerdictLog
        )
        showLastDepositOnLive = Self.loadBool(
            defaults,
            Keys.showLastDepositOnLive,
            WasteSortConfig.defaultShowLastDepositOnLive
        )
        throwFeedbackSoundsEnabled = Self.loadBool(
            defaults,
            Keys.throwFeedbackSounds,
            WasteSortConfig.defaultThrowFeedbackSounds
        )
    }

    func resetToDefaults() {
        confidence = WasteSortConfig.defaultConfidence
        iou = WasteSortConfig.defaultIou
        maxItems = WasteSortConfig.defaultMaxItems
        confirmHits = WasteSortConfig.defaultConfirmHits
        maxMisses = WasteSortConfig.defaultMaxMisses
        trackerIou = WasteSortConfig.defaultTrackerIou
        decisionPipeline = WasteSortConfig.defaultDecisionPipeline
        crossClassIou = WasteSortConfig.defaultCrossClassIou
        beliefThreshold = WasteSortConfig.defaultBeliefThreshold
        beliefMargin = WasteSortConfig.defaultBeliefMargin
        emaAlpha = WasteSortConfig.defaultEmaAlpha
        boxInflate = WasteSortConfig.defaultBoxInflate
        maxSpeed = WasteSortConfig.defaultMaxSpeed
        preferredCameraID = CameraPreference.autoID
        selectedModelName = WasteSortConfig.defaultModelName
        liveRotation = WasteSortConfig.defaultLiveRotation
        liveMirror = WasteSortConfig.defaultLiveMirror
        showConfidence = WasteSortConfig.defaultShowConfidence
        showBoxIcon = WasteSortConfig.defaultShowBoxIcon
        showBoxCategory = WasteSortConfig.defaultShowBoxCategory
        boxLabelPlacement = WasteSortConfig.defaultBoxLabelPlacement
        boxBadgeScale = WasteSortConfig.defaultBoxBadgeScale
        hudTextScale = WasteSortConfig.defaultHUDTextScale
        showZoneOverlay = WasteSortConfig.defaultShowZoneOverlay
        ctaStyle = WasteSortConfig.defaultCTAStyle
        autoRecordOnOpen = WasteSortConfig.defaultAutoRecordOnOpen
        showFPS = WasteSortConfig.defaultShowFPS
        useMockStats = WasteSortConfig.defaultUseMockStats
        voiceGuidanceEnabled = WasteSortConfig.defaultVoiceGuidanceEnabled
        barcodeAssistEnabled = WasteSortConfig.defaultBarcodeAssistEnabled
        appearanceAssistEnabled = WasteSortConfig.defaultAppearanceAssistEnabled
        recheckAssistEnabled = WasteSortConfig.defaultRecheckAssistEnabled
        verboseDetectionLogging = WasteSortConfig.defaultVerboseDetectionLogging
        foundationConfirmationEnabled = WasteSortConfig.defaultFoundationConfirmation
        foundationVerdictLogEnabled = WasteSortConfig.defaultFoundationVerdictLog
        showLastDepositOnLive = WasteSortConfig.defaultShowLastDepositOnLive
        throwFeedbackSoundsEnabled = WasteSortConfig.defaultThrowFeedbackSounds
        resetCaptureToDefaults()
    }

    func resetCaptureToDefaults() {
        brightness = WasteSortConfig.defaultBrightness
        contrast = WasteSortConfig.defaultContrast
        saturation = WasteSortConfig.defaultSaturation
        exposureLocked = WasteSortConfig.defaultExposureLocked
        focusLocked = WasteSortConfig.defaultFocusLocked
        whiteBalanceLocked = WasteSortConfig.defaultWhiteBalanceLocked
    }

    var isCaptureAtDefaults: Bool {
        brightness == WasteSortConfig.defaultBrightness
            && contrast == WasteSortConfig.defaultContrast
            && saturation == WasteSortConfig.defaultSaturation
            && exposureLocked == WasteSortConfig.defaultExposureLocked
            && focusLocked == WasteSortConfig.defaultFocusLocked
            && whiteBalanceLocked == WasteSortConfig.defaultWhiteBalanceLocked
    }

    private func persist(_ value: Double, key: String) {
        defaults.set(value, forKey: key)
    }

    private func persist(_ value: Int, key: String) {
        defaults.set(value, forKey: key)
    }

    private func persist(_ value: String, key: String) {
        defaults.set(value, forKey: key)
    }

    private func persist(_ value: Bool, key: String) {
        defaults.set(value, forKey: key)
    }

    private static func loadDouble(_ defaults: UserDefaults, _ key: String, _ fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }

    private static func loadInt(_ defaults: UserDefaults, _ key: String, _ fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key)
    }

    private static func loadString(_ defaults: UserDefaults, _ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    private static func loadBool(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
