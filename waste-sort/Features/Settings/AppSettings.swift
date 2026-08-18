import Combine
import Foundation

enum WasteSortConfig {
    static let defaultConfidence = 0.6
    static let defaultIou = 0.7
    static let defaultMaxItems = 100

    static let defaultConfirmHits = 2
    static let defaultMaxMisses = 3
    static let defaultTrackerIou = 0.3
    static let defaultEmaAlpha = 0.4
    static let defaultBoxInflate = 0.08
    static let defaultMaxSpeed = 0.8
    static let defaultModelName = WasteSortModel.bestv31.resourceName
    static let defaultLiveRotation = LivePreviewRotation.oneEighty
    static let defaultLiveMirror = false
    static let defaultShowConfidence = false
    static let defaultCTAStyle = CTAStyle.off
}

/// Snapshot of tunable inference and tracking values, passed into Live camera updates.
struct RuntimeSettings: Equatable {
    var confidence: Double
    var iou: Double
    var maxItems: Int
    var confirmHits: Int
    var maxMisses: Int
    var trackerIou: Double
    var emaAlpha: Double
    var boxInflate: Double
    var maxSpeed: Double
    var preferredCameraID: String
    var selectedModelName: String
    var liveRotation: LivePreviewRotation
    var liveMirror: Bool
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
    @Published var ctaStyle: CTAStyle {
        didSet { persist(ctaStyle.rawValue, key: Keys.ctaStyle) }
    }

    var selectedModel: WasteSortModel {
        WasteSortModel.from(resourceName: selectedModelName)
    }

    var runtime: RuntimeSettings {
        RuntimeSettings(
            confidence: confidence,
            iou: iou,
            maxItems: maxItems,
            confirmHits: confirmHits,
            maxMisses: maxMisses,
            trackerIou: trackerIou,
            emaAlpha: emaAlpha,
            boxInflate: boxInflate,
            maxSpeed: maxSpeed,
            preferredCameraID: preferredCameraID,
            selectedModelName: selectedModelName,
            liveRotation: liveRotation,
            liveMirror: liveMirror
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
        static let emaAlpha = "settings.emaAlpha"
        static let boxInflate = "settings.boxInflate"
        /// v2 picks up lower association speed without requiring a manual reset.
        static let maxSpeed = "settings.maxSpeed.v2"
        static let preferredCameraID = "settings.preferredCameraID"
        static let selectedModelName = "settings.selectedModelName"
        static let liveRotation = "settings.liveRotation"
        static let liveMirror = "settings.liveMirror"
        static let showConfidence = "settings.showConfidence"
        static let ctaStyle = "settings.ctaStyle"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        confidence = Self.loadDouble(defaults, Keys.confidence, WasteSortConfig.defaultConfidence)
        iou = Self.loadDouble(defaults, Keys.iou, WasteSortConfig.defaultIou)
        maxItems = Self.loadInt(defaults, Keys.maxItems, WasteSortConfig.defaultMaxItems)
        confirmHits = Self.loadInt(defaults, Keys.confirmHits, WasteSortConfig.defaultConfirmHits)
        maxMisses = Self.loadInt(defaults, Keys.maxMisses, WasteSortConfig.defaultMaxMisses)
        trackerIou = Self.loadDouble(defaults, Keys.trackerIou, WasteSortConfig.defaultTrackerIou)
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
        ctaStyle = CTAStyle(
            rawValue: Self.loadString(defaults, Keys.ctaStyle, WasteSortConfig.defaultCTAStyle.rawValue)
        ) ?? WasteSortConfig.defaultCTAStyle
    }

    func resetToDefaults() {
        confidence = WasteSortConfig.defaultConfidence
        iou = WasteSortConfig.defaultIou
        maxItems = WasteSortConfig.defaultMaxItems
        confirmHits = WasteSortConfig.defaultConfirmHits
        maxMisses = WasteSortConfig.defaultMaxMisses
        trackerIou = WasteSortConfig.defaultTrackerIou
        emaAlpha = WasteSortConfig.defaultEmaAlpha
        boxInflate = WasteSortConfig.defaultBoxInflate
        maxSpeed = WasteSortConfig.defaultMaxSpeed
        preferredCameraID = CameraPreference.autoID
        selectedModelName = WasteSortConfig.defaultModelName
        liveRotation = WasteSortConfig.defaultLiveRotation
        liveMirror = WasteSortConfig.defaultLiveMirror
        showConfidence = WasteSortConfig.defaultShowConfidence
        ctaStyle = WasteSortConfig.defaultCTAStyle
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
