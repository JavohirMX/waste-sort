import AVFoundation
import SwiftUI
import UIKit
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
    var aprilTagEnabled: Bool
    var aprilTagBindings: [UUID: [Int]]
    var aprilTagStaleTimeout: Double
    var aprilTagRangeProfile: AprilTagRangeProfile
    var onBarcodeHint: ((ScannedBarcode?) -> Void)?
    var onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, AprilTagStatusFrame) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            settings: settings,
            preferredCameraID: preferredCameraID,
            selectedModelName: selectedModelName,
            recording: recording,
            zones: zones,
            dwellFrames: dwellFrames,
            reacquireGrace: reacquireGrace,
            aprilTagEnabled: aprilTagEnabled,
            aprilTagBindings: aprilTagBindings,
            aprilTagStaleTimeout: aprilTagStaleTimeout,
            aprilTagRangeProfile: aprilTagRangeProfile,
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
            settings: settings,
            zones: zones,
            dwellFrames: dwellFrames,
            reacquireGrace: reacquireGrace,
            aprilTagEnabled: aprilTagEnabled,
            aprilTagBindings: aprilTagBindings,
            aprilTagStaleTimeout: aprilTagStaleTimeout
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
        context.coordinator.onBarcodeHint = onBarcodeHint
        context.coordinator.yoloView = uiView
        context.coordinator.replaceInputs(
            settings: settings,
            zones: zones,
            dwellFrames: dwellFrames,
            reacquireGrace: reacquireGrace,
            aprilTagEnabled: aprilTagEnabled,
            aprilTagBindings: aprilTagBindings,
            aprilTagStaleTimeout: aprilTagStaleTimeout
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

    final class Coordinator {
        var onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, AprilTagStatusFrame) -> Void)?
        var onBarcodeHint: ((ScannedBarcode?) -> Void)?
        /// Throttled Vision pass; runs beside the AprilTag luma tap.
        let barcodeScanner = BarcodeFrameScanner()
        var preferredCameraID: String
        var selectedModelName: String
        let recording: RecordingController
        /// Read by `handle` on the inference queue; mirrors the published phase.
        private let phaseMirror: RecordingPhaseMirror

        // MARK: Cross-thread state (main writes, camera queue reads)
        private let inputsLock = NSLock()
        private var _inputs: PipelineInputs
        private var _capturingOriginals = false

        var capturingOriginals: Bool {
            get {
                inputsLock.lock()
                defer { inputsLock.unlock() }
                return _capturingOriginals
            }
            set {
                inputsLock.lock()
                _capturingOriginals = newValue
                inputsLock.unlock()
            }
        }

        weak var yoloView: YOLOView?
        let tracker = DetectionTracker()
        let depositDetector = ZoneDepositDetector()
        let aprilTagPipeline = AprilTagFramePipeline(
            detector: AprilTagDetector(familyName: "tag16h5", tuning: AprilTagRangeProfile.far.tuning)
        )
        let aprilTagBinDetector = AprilTagBinStateDetector()
        private var cameraObservers: [NSObjectProtocol] = []
        private var applyWorkItem: DispatchWorkItem?
        private var isReloadingModel = false
        private var lastAppliedCaptureDeviceID: String?
        private var lastAppliedCaptureControls: CameraCaptureControls?
        private var frameColorProxy: VideoFrameColorProxy?

        var aprilTagRangeProfile: AprilTagRangeProfile = .far {
            didSet {
                guard oldValue != aprilTagRangeProfile else { return }
                aprilTagPipeline.apply(tuning: aprilTagRangeProfile.tuning)
                aprilTagPipeline.reset()
                applyCaptureResolution(force: true)
            }
        }

        init(
            settings: RuntimeSettings,
            preferredCameraID: String,
            selectedModelName: String,
            recording: RecordingController,
            zones: [DropZone],
            dwellFrames: Int,
            reacquireGrace: Double,
            aprilTagEnabled: Bool,
            aprilTagBindings: [UUID: [Int]],
            aprilTagStaleTimeout: Double,
            aprilTagRangeProfile: AprilTagRangeProfile,
            onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, AprilTagStatusFrame) -> Void)?
        ) {
            self.preferredCameraID = preferredCameraID
            self.selectedModelName = selectedModelName
            self.recording = recording
            self.phaseMirror = recording.phaseMirror
            self._inputs = PipelineInputs(
                settings: settings,
                zones: zones,
                dwellFrames: dwellFrames,
                reacquireGrace: reacquireGrace,
                aprilTagEnabled: aprilTagEnabled,
                aprilTagBindings: aprilTagBindings,
                aprilTagStaleTimeout: aprilTagStaleTimeout
            )
            self.aprilTagRangeProfile = aprilTagRangeProfile
            self.onDetection = onDetection
            self.onBarcodeHint = nil
            barcodeScanner.onBarcode = { [weak self] barcode in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.onBarcodeHint?(barcode)
                }
            }
            aprilTagPipeline.apply(tuning: aprilTagRangeProfile.tuning)
        }

        /// Atomically swaps everything `handle` reads. Main thread only.
        func replaceInputs(
            settings: RuntimeSettings,
            zones: [DropZone],
            dwellFrames: Int,
            reacquireGrace: Double,
            aprilTagEnabled: Bool,
            aprilTagBindings: [UUID: [Int]],
            aprilTagStaleTimeout: Double
        ) {
            let snapshot = PipelineInputs(
                settings: settings,
                zones: zones,
                dwellFrames: dwellFrames,
                reacquireGrace: reacquireGrace,
                aprilTagEnabled: aprilTagEnabled,
                aprilTagBindings: aprilTagBindings,
                aprilTagStaleTimeout: aprilTagStaleTimeout
            )
            inputsLock.lock()
            _inputs = snapshot
            inputsLock.unlock()
        }

        func handle(_ result: YOLOResult) {
            inputsLock.lock()
            let inputs = _inputs
            let shouldCapture = switch phaseMirror.current {
            case .starting, .recording, .stopping: true
            case .idle, .saving: false
            }
            var captureToggle: Bool?
            if _capturingOriginals != shouldCapture {
                _capturingOriginals = shouldCapture
                captureToggle = shouldCapture
            }
            inputsLock.unlock()

            // Tracker/deposit knobs live on the inference queue: applying them here
            // from the immutable snapshot keeps main-thread writes out of these objects.
            tracker.iouThreshold = CGFloat(inputs.settings.trackerIou)
            tracker.confirmHits = inputs.settings.confirmHits
            tracker.maxMisses = inputs.settings.maxMisses
            tracker.crossClassIouThreshold = CGFloat(inputs.settings.crossClassIou)
            tracker.beliefDecideThreshold = inputs.settings.beliefThreshold
            tracker.beliefDecideMargin = inputs.settings.beliefMargin
            tracker.emaAlpha = CGFloat(inputs.settings.emaAlpha)
            tracker.boxInflate = CGFloat(inputs.settings.boxInflate)
            tracker.maxSpeed = CGFloat(inputs.settings.maxSpeed)

            if let enable = captureToggle, let view = yoloView {
                YOLOViewPredictorAccess.setCapturesOriginalImage(enable, in: view)
            }
            let minConf = Float(inputs.settings.confidence)
            let raw: [RawDetection] = result.boxes.compactMap { box in
                guard box.conf >= minConf else { return nil }
                let key = BinGuide.normalizedKey(box.cls)
                return RawDetection(
                    classKey: key,
                    className: box.cls,
                    conf: box.conf,
                    xywhn: box.xywhn
                )
            }
            let tracked = tracker.update(raw)
            let currentZones = inputs.zones
            depositDetector.requiredDwellFrames = inputs.dwellFrames
            depositDetector.reacquireGrace = inputs.reacquireGrace
            var tagFrame = inputs.aprilTagEnabled
                ? aprilTagBinDetector.update(
                    zones: currentZones,
                    tagBindings: inputs.aprilTagBindings,
                    config: AprilTagConfig(staleTimeout: inputs.aprilTagStaleTimeout)
                )
                : AprilTagStatusFrame()
            if inputs.aprilTagEnabled {
                tagFrame.detectorStats = aprilTagPipeline.detector.lastFrameStats
                tagFrame.detectorFailureReason = aprilTagPipeline.detector.configurationFailureReason
            }
            depositDetector.binOpenState = FrameBinOpenState(tagFrame: tagFrame, zones: currentZones)
            let zoneFrame = depositDetector.update(tracks: tracked, zones: currentZones)
            if phaseMirror.current == .recording {
                let fps = result.fps.flatMap { $0.isFinite ? Int($0.rounded()) : nil } ?? 0
                recording.ingestLiveFrame(
                    tracks: tracked,
                    deposits: zoneFrame.deposits,
                    originalImage: result.originalImage,
                    fps: fps,
                    settings: inputs.settings
                )
            }
            // Zone results ride the existing main-thread hop so the @Published history
            // append never happens off-main.
            DispatchQueue.main.async {
                self.onDetection?(result, tracked, zoneFrame, tagFrame)
            }
        }

        func startObservingCameraChanges() {
            stopObservingCameraChanges()
            _ = CameraDeviceCatalog.availableOptions()

            let center = NotificationCenter.default
            cameraObservers = [
                center.addObserver(
                    forName: AVCaptureDevice.wasConnectedNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.applyPreferredCamera()
                },
                center.addObserver(
                    forName: AVCaptureDevice.wasDisconnectedNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.applyPreferredCamera()
                }
            ]
        }

        func stopObservingCameraChanges() {
            applyWorkItem?.cancel()
            applyWorkItem = nil
            for observer in cameraObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            cameraObservers.removeAll()
        }

        func schedulePreferredCameraApply(retries: Int) {
            applyWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.registerCaptureSessionIfNeeded()
                if self.applyPreferredCamera() {
                    self.registerCaptureSessionIfNeeded()
                    self.installFrameColorProxyIfNeeded()
                    return
                }
                if retries > 0 {
                    self.schedulePreferredCameraApply(retries: retries - 1)
                }
            }
            applyWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        @discardableResult
        func applyPreferredCamera() -> Bool {
            guard let view = yoloView,
                  let device = CameraDeviceCatalog.resolveDevice(preferenceID: preferredCameraID)
            else {
                return false
            }

            if YOLOViewCameraSwitcher.currentDeviceUniqueID(in: view) == device.uniqueID {
                applyCaptureResolution()
                registerCaptureSessionIfNeeded()
                applyCaptureControlsIfNeeded()
                installFrameColorProxyIfNeeded()
                return true
            }

            let ok = YOLOViewCameraSwitcher.switchTo(device, in: view)
            if ok {
                applyCaptureResolution(force: true)
                lastAppliedCaptureDeviceID = nil
                registerCaptureSessionIfNeeded()
                applyCaptureControlsIfNeeded()
                installFrameColorProxyIfNeeded()
            }
            return ok
        }

        func updateFrameColorControls() {
            frameColorProxy?.controls = currentInputs.settings.frameColor
            frameColorProxy?.syncPreviewLayout()
        }

        private var currentInputs: PipelineInputs {
            inputsLock.lock()
            defer { inputsLock.unlock() }
            return _inputs
        }

        func installFrameColorProxyIfNeeded() {
            guard let view = yoloView else { return }
            if frameColorProxy == nil {
                frameColorProxy = VideoFrameColorProxy()
            }
            // The tap copies luma here on the camera queue and detects on the pipeline's own
            // queue. Running the pass inline would cost YOLO an inference frame per detection.
            frameColorProxy?.frameTap = { [weak self] pixelBuffer in
                guard let self else { return }
                if self.currentInputs.aprilTagEnabled {
                    self.aprilTagPipeline.submit(pixelBuffer)
                }
                if self.currentInputs.settings.barcodeAssistEnabled {
                    self.barcodeScanner.submit(pixelBuffer)
                }
            }
            aprilTagPipeline.onTags = { [weak self] tags, timestamp in
                self?.aprilTagBinDetector.ingest(tags: tags, timestamp: timestamp)
            }
            frameColorProxy?.controls = currentInputs.settings.frameColor
            frameColorProxy?.install(on: view)
            frameColorProxy?.syncPreviewLayout()
        }

        func uninstallFrameColorProxy() {
            frameColorProxy?.uninstall()
            frameColorProxy = nil
        }

        /// Raises the session preset to whatever the range profile asks for.
        ///
        /// Set directly on the session rather than through `YOLOView.captureSessionPreset`,
        /// whose setter tears the capture down and restarts it - which would drop the frame
        /// colour proxy and the AprilTag tap along with it.
        func applyCaptureResolution(force: Bool = false) {
            guard let view = yoloView,
                  let session = YOLOViewCameraSwitcher.captureSession(in: view)
            else {
                return
            }
            let wanted = aprilTagRangeProfile.captureSessionPresets
            guard force || !wanted.contains(session.sessionPreset) else { return }
            guard let preset = wanted.first(where: { session.canSetSessionPreset($0) }),
                  session.sessionPreset != preset
            else {
                return
            }
            session.beginConfiguration()
            session.sessionPreset = preset
            session.commitConfiguration()
        }

        func applyCaptureControlsIfNeeded() {
            guard let view = yoloView,
                  let device = YOLOViewCameraSwitcher.currentVideoDevice(in: view)
            else {
                return
            }
            let controls = currentInputs.settings.captureControls
            if lastAppliedCaptureDeviceID == device.uniqueID,
               lastAppliedCaptureControls == controls {
                return
            }
            CameraCaptureAdjuster.apply(controls, to: device)
            lastAppliedCaptureDeviceID = device.uniqueID
            lastAppliedCaptureControls = controls
        }

        func registerCaptureSessionIfNeeded() {
            guard yoloView != nil else { return }
            // Defer so we never publish ObservableObject changes mid-view-update.
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.yoloView else { return }
                self.recording.register(from: view)
            }
        }

        func reloadModel(named name: String) {
            guard let view = yoloView, !isReloadingModel else { return }
            isReloadingModel = true
            view.setModel(modelPathOrName: name, task: .segment) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isReloadingModel = false
                    if case .success = result {
                        LiveYOLOCamera.applyThresholds(view, settings: self.currentInputs.settings)
                        if self.capturingOriginals {
                            YOLOViewPredictorAccess.setCapturesOriginalImage(true, in: view)
                        }
                        self.applyPreferredCamera()
                        self.registerCaptureSessionIfNeeded()
                        self.applyCaptureControlsIfNeeded()
                        self.installFrameColorProxyIfNeeded()
                    }
                }
            }
        }
    }
}

/// Immutable pipeline configuration owned by the main thread and swapped
/// atomically before each read on the YOLO inference queue.
///
/// `Coordinator.handle` runs on Ultralytics' camera/predictor queue while SwiftUI
/// writes configuration from `updateUIView` on the main thread. Passing this
/// snapshot instead of letting both sides touch plain stored properties removes
/// the data race without introducing actor hops on the frame path.
private struct PipelineInputs {
    var settings: RuntimeSettings
    var zones: [DropZone]
    var dwellFrames: Int
    var reacquireGrace: Double
    var aprilTagEnabled: Bool
    var aprilTagBindings: [UUID: [Int]]
    var aprilTagStaleTimeout: Double
}
