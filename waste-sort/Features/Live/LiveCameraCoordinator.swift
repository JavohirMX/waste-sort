import AVFoundation
import SwiftUI
import UIKit
import UltralyticsYOLO

/// The camera-side brain: owns tracker, deposit detector, both lid signals,
/// and the PCC judge queue. All mutable pipeline state is inference-queue owned;
/// configuration crosses from main via `PipelineInputs`.
final class LiveCameraCoordinator {
    var onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, BinOpennessSnapshot, ConfirmationFrame, [FoundationVerdictRecord]) -> Void)?
    var onPresentationDelta: ((LivePreviewRotation) -> Void)?
    var onBarcodeHint: ((ScannedBarcode?) -> Void)?
    /// Throttled Vision pass; runs beside the AprilTag luma tap.
    let barcodeScanner = BarcodeFrameScanner()
    /// On-device Foundation category confirmation; inert unless enabled and supported.
    let confirmation = CategoryConfirmationCoordinator(service: FoundationCategoryConfirmer())
    /// Resolved once: the answer involves a `dlsym` sweep and a system model query.
    private lazy var isConfirmationSupported = FoundationCategoryAvailability.current.isReady
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
    /// Color/texture evidence for the belief engines. Inference-queue owned.
    let appearanceSampler = BoxAppearanceSampler()
    var lastAppearanceSampleAt: CFAbsoluteTime = 0
    /// Crop-and-recheck escalation for unsure items. Requests fire from the
    /// inference queue; outcomes return via a lock-guarded buffer drained on the
    /// next frame, because the engine's completion runs on its own queue.
    let zoomRecheck = ZoomRecheckEngine()
    /// Silent PCC second opinions for uncertain deposits (specs/001). Created
    /// lazily so a kiosk that never qualifies a deposit never touches store or
    /// availability APIs. Own work happens off the inference queue.
    lazy var pccJudge: PCCArbiterService = PCCArbiterService(store: PCCRecordStore())
    /// Serial line in front of the judge: back-to-back throws wait their turn
    /// instead of stampeding quota; exhausted quota holds entries until reset.
    lazy var pccQueue = PCCJudgeQueue(arbiter: pccJudge)
    /// Consecutive frames per track id, feeding the verdict-audit trigger.
    /// Inference-queue owned; entries for vanished ids are pruned each frame.
    var verdictAuditFrames: [Int: Int] = [:]
    let recheckBufferLock = NSLock()
    var pendingRecheckOutcomes: [ZoomRecheckOutcome] = []
    let aprilTagPipeline = AprilTagFramePipeline(
        detector: AprilTagDetector(familyName: "tag16h5", tuning: AprilTagRangeProfile.far.tuning)
    )
    let aprilTagBinDetector = AprilTagBinStateDetector()
    /// The other lid signal: printed strips instead of tags. Idle unless
    /// `BinOpennessInputs.source` selects it, so the two never both gate a frame.
    let markerPipeline = BinMarkerFramePipeline()
    let markerBinDetector = BinMarkerStateDetector()
    var cameraObservers: [NSObjectProtocol] = []
    var applyWorkItem: DispatchWorkItem?
    var isReloadingModel = false
    var lastAppliedCaptureDeviceID: String?
    var lastAppliedCaptureControls: CameraCaptureControls?
    var frameColorProxy: VideoFrameColorProxy?
    var lastPresentationDelta: LivePreviewRotation?

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
        throwFeedbackGrace: Double,
        aprilTagEnabled: Bool,
        aprilTagBindings: [UUID: [Int]],
        aprilTagStaleTimeout: Double,
        aprilTagRangeProfile: AprilTagRangeProfile,
        openness: BinOpennessInputs,
        foundationConfirmationEnabled: Bool,
        onPresentationDelta: ((LivePreviewRotation) -> Void)?,
        onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, BinOpennessSnapshot, ConfirmationFrame, [FoundationVerdictRecord]) -> Void)?
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
            throwFeedbackGrace: throwFeedbackGrace,
            aprilTagEnabled: aprilTagEnabled,
            aprilTagBindings: aprilTagBindings,
            aprilTagStaleTimeout: aprilTagStaleTimeout,
            openness: openness
        )
        self.aprilTagRangeProfile = aprilTagRangeProfile
        self.onDetection = onDetection
        self.onPresentationDelta = onPresentationDelta
        self.onBarcodeHint = nil
        setConfirmationEnabled(foundationConfirmationEnabled)
        barcodeScanner.onBarcode = { [weak self] barcode in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onBarcodeHint?(barcode)
            }
        }
        aprilTagPipeline.apply(tuning: aprilTagRangeProfile.tuning)
    }

    var currentInputs: PipelineInputs {
        inputsLock.lock()
        defer { inputsLock.unlock() }
        return _inputs
    }

    /// Atomically swaps everything `handle` reads. Main thread only.
    func replaceInputs(_ newInputs: PipelineInputs) {
        inputsLock.lock()
        _inputs = newInputs
        inputsLock.unlock()
    }

    /// The layer only runs when the operator asked for it *and* the device can actually
    /// serve it. Turning it off drops every locked verdict, so the next frame is back to
    /// the detector's own labels with nothing stale hanging around.
    func setConfirmationEnabled(_ enabled: Bool) {
        let wanted = enabled && isConfirmationSupported
        guard confirmation.isEnabled != wanted else { return }
        confirmation.isEnabled = wanted
        if !wanted {
            confirmation.reset()
        }
    }

    /// Applies the detector knobs and refreshes both lid signals for this frame,
    /// returning the merged openness snapshot. Inference-queue only.
    private func applyDepositInputs(
        _ inputs: PipelineInputs,
        zones: [DropZone]
    ) -> BinOpennessSnapshot {
        depositDetector.requiredDwellFrames = inputs.dwellFrames
        depositDetector.reacquireGrace = inputs.reacquireGrace
        depositDetector.throwFeedbackGrace = inputs.throwFeedbackGrace
        let usesTags = inputs.aprilTagEnabled && !inputs.openness.usesMarkers
        var tagFrame = usesTags
            ? aprilTagBinDetector.update(
                zones: zones,
                tagBindings: inputs.aprilTagBindings,
                config: AprilTagConfig(staleTimeout: inputs.aprilTagStaleTimeout)
            )
            : AprilTagStatusFrame()
        if usesTags {
            tagFrame.detectorStats = aprilTagPipeline.detector.lastFrameStats
            tagFrame.detectorFailureReason = aprilTagPipeline.detector.configurationFailureReason
        }
        var markerFrame = BinMarkerStatusFrame()
        if inputs.openness.usesMarkers {
            markerFrame = markerBinDetector.update(
                zones: zones,
                config: BinMarkerStateConfig(staleTimeout: inputs.openness.markerStaleTimeout)
            )
            markerFrame.stats = inputs.openness.markerKind.style.usesDashRows
                ? markerPipeline.dashScanner.lastFrameStats
                : markerPipeline.scanner.lastFrameStats
        }
        let openness = BinOpennessSnapshot(
            source: inputs.openness.source,
            tag: tagFrame,
            marker: markerFrame
        )
        depositDetector.binOpenState = openness.openState(zones: zones)
        return openness
    }

    func handle(_ result: YOLOResult) {
        inputsLock.lock()
        let inputs = _inputs
        let shouldCapture = switch phaseMirror.current {
        case .starting, .recording, .stopping: true
        // Appearance priors, the zoom re-check, and Foundation confirmation all need
        // frames while idle; without them the kiosk's main mode runs blind to those
        // signals. The first two feed beliefs, so they are inert under legacy.
        case .idle:
            confirmation.isEnabled
                || inputs.settings.pccJudgeEnabled
                || (inputs.settings.decisionPipeline == .belief
                    && (inputs.settings.appearanceAssistEnabled || inputs.settings.recheckAssistEnabled))
        case .saving: false
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
        tracker.pipeline = inputs.settings.decisionPipeline
        depositDetector.pipeline = inputs.settings.decisionPipeline
        tracker.confirmHits = inputs.settings.confirmHits
        tracker.maxMisses = inputs.settings.maxMisses
        tracker.crossClassIouThreshold = CGFloat(inputs.settings.crossClassIou)
        tracker.beliefDecideThreshold = inputs.settings.beliefThreshold
        tracker.beliefDecideMargin = inputs.settings.beliefMargin
        tracker.emaAlpha = CGFloat(inputs.settings.emaAlpha)
        tracker.boxInflate = CGFloat(inputs.settings.boxInflate)
        tracker.maxSpeed = CGFloat(inputs.settings.maxSpeed)
        tracker.appearanceEvidenceWeight = inputs.settings.appearanceAssistEnabled
            ? WasteSortConfig.defaultAppearanceWeight
            : 0

        if let enable = captureToggle, let view = yoloView {
            YOLOViewPredictorAccess.setCapturesOriginalImage(enable, in: view)
        }
        let minConf = Float(inputs.settings.confidence)
        drainRecheckOutcomes()
        var priorsByKey: [Int: AppearancePrior] = [:]
        if inputs.settings.appearanceAssistEnabled, inputs.settings.decisionPipeline == .belief,
           let image = result.originalImage {
            priorsByKey = sampleAppearancePriors(image: image, boxes: result.boxes)
        }
        let raw: [RawDetection] = result.boxes.compactMap { box in
            guard box.conf >= minConf else { return nil }
            let key = BinGuide.normalizedKey(box.cls)
            return RawDetection(
                classKey: key,
                className: box.cls,
                conf: box.conf,
                xywhn: box.xywhn,
                appearancePrior: priorsByKey[box.index]
            )
        }
        // Everything downstream — boxes, the category bar, the CTA, deposits, the log —
        // reads the confirmed labels, because a verdict nobody acts on is decoration.
        let (tracked, confirmationFrame, verdictRecords) = confirmation.update(
            tracks: tracker.update(raw),
            frameImage: { result.originalImage.flatMap(UprightFrameImage.cgImage(from:)) }
        )
        if inputs.settings.recheckAssistEnabled, inputs.settings.decisionPipeline == .belief,
           let image = result.originalImage {
            requestRechecks(
                for: tracked,
                image: image,
                settings: inputs.settings
            )
        }
        let currentZones = inputs.zones
        let openness = applyDepositInputs(inputs, zones: currentZones)
        let zoneFrame = depositDetector.update(tracks: tracked, zones: currentZones)
        runPCCPasses(
            zoneFrame: zoneFrame,
            tracked: tracked,
            confirmationFrame: confirmationFrame,
            originalImage: result.originalImage,
            settings: inputs.settings
        )
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
            self.onDetection?(
                result,
                tracked,
                zoneFrame,
                openness,
                confirmationFrame,
                verdictRecords
            )
        }
    }
}

/// Immutable pipeline configuration owned by the main thread and swapped
/// atomically before each read on the YOLO inference queue.
///
/// `LiveCameraCoordinator.handle` runs on Ultralytics' camera/predictor queue while
/// SwiftUI writes configuration from `updateUIView` on the main thread. Passing this
/// snapshot instead of letting both sides touch plain stored properties removes
/// the data race without introducing actor hops on the frame path.
struct PipelineInputs {
    var settings: RuntimeSettings
    var zones: [DropZone]
    var dwellFrames: Int
    var reacquireGrace: Double
    var throwFeedbackGrace: Double
    var aprilTagEnabled: Bool
    var aprilTagBindings: [UUID: [Int]]
    var aprilTagStaleTimeout: Double
    var openness: BinOpennessInputs = BinOpennessInputs()
}
