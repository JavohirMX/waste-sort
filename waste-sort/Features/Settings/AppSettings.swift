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
    static let defaultClassLockWindow = 0.40
    static let defaultEmaAlpha = 0.4
    static let defaultBoxInflate = 0.08
    static let defaultMaxSpeed = 0.8
    static let defaultModelName = WasteSortModel.bestv35.resourceName
    static let defaultLiveRotation = LivePreviewRotation.oneEighty
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
}

/// Snapshot of tunable inference and tracking values, passed into Live camera updates.
struct RuntimeSettings: Equatable {
    var confidence: Double
    var iou: Double
    var maxItems: Int
    var barcodeAssistEnabled: Bool
    var confirmHits: Int
    var maxMisses: Int
    var trackerIou: Double
    var crossClassIou: Double
    var classLockWindow: Double
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
    @Published var classLockWindow: Double {
        didSet { persist(classLockWindow, key: Keys.classLockWindow) }
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
    /// Gates the first-launch onboarding flow. Intentionally left out of `resetToDefaults()`
    /// so restoring tuning values does not relaunch the tutorial — Settings offers a
    /// dedicated "Show onboarding again" action instead.
    @Published var hasCompletedOnboarding: Bool {
        didSet { persist(hasCompletedOnboarding, key: Keys.hasCompletedOnboarding) }
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
            barcodeAssistEnabled: barcodeAssistEnabled,
            confirmHits: confirmHits,
            maxMisses: maxMisses,
            trackerIou: trackerIou,
            crossClassIou: crossClassIou,
            classLockWindow: classLockWindow,
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
        static let classLockWindow = "settings.classLockWindow"
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
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
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
        trackerIou = Self.loadDouble(defaults, Keys.trackerIou, WasteSortConfig.defaultTrackerIou)
        crossClassIou = Self.loadDouble(defaults, Keys.crossClassIou, WasteSortConfig.defaultCrossClassIou)
        classLockWindow = Self.loadDouble(
            defaults,
            Keys.classLockWindow,
            WasteSortConfig.defaultClassLockWindow
        )
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
        voiceGuidanceEnabled = Self.loadBool(
            defaults,
            Keys.voiceGuidanceEnabled,
            WasteSortConfig.defaultVoiceGuidanceEnabled
        )
        barcodeAssistEnabled = Self.loadBool(
            defaults,
            Keys.barcodeAssistEnabled,
            WasteSortConfig.defaultBarcodeAssistEnabled
        )
        hasCompletedOnboarding = Self.loadBool(
            defaults,
            Keys.hasCompletedOnboarding,
            WasteSortConfig.defaultHasCompletedOnboarding
        )
    }

    func resetToDefaults() {
        confidence = WasteSortConfig.defaultConfidence
        iou = WasteSortConfig.defaultIou
        maxItems = WasteSortConfig.defaultMaxItems
        confirmHits = WasteSortConfig.defaultConfirmHits
        maxMisses = WasteSortConfig.defaultMaxMisses
        trackerIou = WasteSortConfig.defaultTrackerIou
        crossClassIou = WasteSortConfig.defaultCrossClassIou
        classLockWindow = WasteSortConfig.defaultClassLockWindow
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
