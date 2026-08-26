import Foundation

// MARK: - Reset-to-defaults, persistence, and defaults loading

extension AppSettings {
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
        pccJudgeEnabled = WasteSortConfig.defaultPCCJudgeEnabled
        pccConfidentAuditEnabled = WasteSortConfig.defaultPCCConfidentAuditEnabled
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

    func persist(_ value: Double, key: String) {
        defaults.set(value, forKey: key)
    }

    func persist(_ value: Int, key: String) {
        defaults.set(value, forKey: key)
    }

    func persist(_ value: String, key: String) {
        defaults.set(value, forKey: key)
    }

    func persist(_ value: Bool, key: String) {
        defaults.set(value, forKey: key)
    }

    static func loadDouble(_ defaults: UserDefaults, _ key: String, _ fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }

    static func loadInt(_ defaults: UserDefaults, _ key: String, _ fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key)
    }

    static func loadString(_ defaults: UserDefaults, _ key: String, _ fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    static func loadBool(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}
