import SwiftUI
import UltralyticsYOLO

/// YOLOCamera wrapper that loads the selected segment model, sets thresholds, and hides developer chrome.
struct LiveYOLOCamera: UIViewRepresentable {
    var settings: RuntimeSettings
    var preferredCameraID: String
    var selectedModelName: String
    var recording: RecordingController
    var zones: [DropZone]
    var dwellFrames: Int
    var reacquireGrace: Double
    var throwFeedbackGrace: Double
    var aprilTagEnabled: Bool
    var aprilTagBindings: [UUID: [Int]]
    var aprilTagStaleTimeout: Double
    var aprilTagRangeProfile: AprilTagRangeProfile
    var openness: BinOpennessInputs
    var foundationConfirmationEnabled: Bool
    var onPresentationDelta: ((LivePreviewRotation) -> Void)?
    var onBarcodeHint: ((ScannedBarcode?) -> Void)?
    var onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, BinOpennessSnapshot, ConfirmationFrame, [FoundationVerdictRecord]) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            settings: settings,
            preferredCameraID: preferredCameraID,
            selectedModelName: selectedModelName,
            recording: recording,
            zones: zones,
            dwellFrames: dwellFrames,
            reacquireGrace: reacquireGrace,
            throwFeedbackGrace: throwFeedbackGrace,
            aprilTagEnabled: aprilTagEnabled,
            aprilTagBindings: aprilTagBindings,
            aprilTagStaleTimeout: aprilTagStaleTimeout,
            aprilTagRangeProfile: aprilTagRangeProfile,
            openness: openness,
            foundationConfirmationEnabled: foundationConfirmationEnabled,
            onPresentationDelta: onPresentationDelta,
            onDetection: onDetection
        )
    }

    func makeUIView(context: Context) -> YOLOView {
        let view = YOLOView(
            frame: .zero,
            modelPathOrName: selectedModelName,
            task: .segment
        )
        Self.applyThresholds(view, settings: settings)
        context.coordinator.replaceInputs(
            PipelineInputs(
                settings: settings,
                zones: zones,
                dwellFrames: dwellFrames,
                reacquireGrace: reacquireGrace,
                throwFeedbackGrace: throwFeedbackGrace,
                aprilTagEnabled: aprilTagEnabled,
                aprilTagBindings: aprilTagBindings,
                aprilTagStaleTimeout: aprilTagStaleTimeout,
                openness: openness
            )
        )
        view.showOverlays = false
        hideDeveloperChrome(view)
        let coordinator = context.coordinator
        coordinator.yoloView = view
        coordinator.preferredCameraID = preferredCameraID
        coordinator.selectedModelName = selectedModelName
        coordinator.startObservingCameraChanges()
        view.onDetection = { result in
            coordinator.handle(result)
        }
        coordinator.schedulePreferredCameraApply(retries: 20)
        return view
    }

    func updateUIView(_ uiView: YOLOView, context: Context) {
        context.coordinator.onDetection = onDetection
        context.coordinator.setConfirmationEnabled(foundationConfirmationEnabled)
        context.coordinator.onPresentationDelta = onPresentationDelta
        context.coordinator.onBarcodeHint = onBarcodeHint
        context.coordinator.yoloView = uiView
        context.coordinator.replaceInputs(
            PipelineInputs(
                settings: settings,
                zones: zones,
                dwellFrames: dwellFrames,
                reacquireGrace: reacquireGrace,
                throwFeedbackGrace: throwFeedbackGrace,
                aprilTagEnabled: aprilTagEnabled,
                aprilTagBindings: aprilTagBindings,
                aprilTagStaleTimeout: aprilTagStaleTimeout,
                openness: openness
            )
        )
        Self.applyThresholds(uiView, settings: settings)
        let coordinator = context.coordinator
        uiView.onDetection = { result in
            coordinator.handle(result)
        }
        uiView.showOverlays = false
        hideDeveloperChrome(uiView)

        if coordinator.preferredCameraID != preferredCameraID {
            coordinator.preferredCameraID = preferredCameraID
            coordinator.applyPreferredCamera()
        }

        if coordinator.selectedModelName != selectedModelName {
            coordinator.selectedModelName = selectedModelName
            coordinator.reloadModel(named: selectedModelName)
        }
        // Triggers the tuning/reset didSet when changed; main-thread only.
        context.coordinator.aprilTagRangeProfile = aprilTagRangeProfile
        coordinator.applyCaptureControlsIfNeeded()
        coordinator.updateFrameColorControls()
        // Tracker/deposit knobs are applied inside handle() from the snapshot so
        // the inference queue never races main-thread writes on those objects.
        // Do not register the capture session here: updateUIView runs on every
        // SwiftUI refresh (including each detection frame). Publishing from
        // RecordingController during that path caused a 100% CPU update loop.
    }

    static func dismantleUIView(_ uiView: YOLOView, coordinator: Coordinator) {
        coordinator.stopObservingCameraChanges()
        coordinator.uninstallFrameColorProxy()
        YOLOViewPredictorAccess.setCapturesOriginalImage(false, in: uiView)
        coordinator.capturingOriginals = false
        // Clear after the current update cycle so we don't publish mid-teardown.
        DispatchQueue.main.async {
            coordinator.recording.register(session: nil)
        }
    }

    static func applyThresholds(_ view: YOLOView, settings: RuntimeSettings) {
        view.setConfidenceThreshold(settings.confidence)
        view.setIouThreshold(settings.iou)
        view.setNumItemsThreshold(settings.maxItems)
    }

    private func hideDeveloperChrome(_ view: YOLOView) {
        view.sliderNumItems.isHidden = true
        view.labelSliderNumItems.isHidden = true
        view.sliderConf.isHidden = true
        view.labelSliderConf.isHidden = true
        view.sliderIoU.isHidden = true
        view.labelSliderIoU.isHidden = true
        view.labelName.isHidden = true
        view.labelFPS.isHidden = true
        view.labelBreakdown.isHidden = true
        view.labelZoom.isHidden = true
        view.playButton.isHidden = true
        view.pauseButton.isHidden = true
        view.switchCameraButton.isHidden = true
        view.shareButton.isHidden = true
        view.infoButton.isHidden = true
        view.toolbar.isHidden = true
    }

    /// The camera-side brain. Body lives in `LiveCameraCoordinator.swift` and its
    /// responsibility-scoped extension files beside this one.
    typealias Coordinator = LiveCameraCoordinator
}
