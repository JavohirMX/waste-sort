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
        private let appearanceSampler = BoxAppearanceSampler()
        private var lastAppearanceSampleAt: CFAbsoluteTime = 0
        /// Crop-and-recheck escalation for unsure items. Requests fire from the
        /// inference queue; outcomes return via a lock-guarded buffer drained on the
        /// next frame, because the engine's completion runs on its own queue.
        private let zoomRecheck = ZoomRecheckEngine()
        /// Silent PCC second opinions for uncertain deposits (specs/001). Created
        /// lazily so a kiosk that never qualifies a deposit never touches store or
        /// availability APIs. Own work happens off the inference queue.
        private lazy var pccJudge: PCCArbiterService = PCCArbiterService(store: PCCRecordStore())
        private let recheckBufferLock = NSLock()
        private var pendingRecheckOutcomes: [ZoomRecheckOutcome] = []
        let aprilTagPipeline = AprilTagFramePipeline(
            detector: AprilTagDetector(familyName: "tag16h5", tuning: AprilTagRangeProfile.far.tuning)
        )
        let aprilTagBinDetector = AprilTagBinStateDetector()
        /// The other lid signal: printed strips instead of tags. Idle unless
        /// `BinOpennessInputs.source` selects it, so the two never both gate a frame.
        let markerPipeline = BinMarkerFramePipeline()
        let markerBinDetector = BinMarkerStateDetector()
        private var cameraObservers: [NSObjectProtocol] = []
        private var applyWorkItem: DispatchWorkItem?
        private var isReloadingModel = false
        private var lastAppliedCaptureDeviceID: String?
        private var lastAppliedCaptureControls: CameraCaptureControls?
        private var frameColorProxy: VideoFrameColorProxy?
        private var lastPresentationDelta: LivePreviewRotation?

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

        /// Atomically swaps everything `handle` reads. Main thread only.
        func replaceInputs(
            settings: RuntimeSettings,
            zones: [DropZone],
            dwellFrames: Int,
            reacquireGrace: Double,
            throwFeedbackGrace: Double,
            aprilTagEnabled: Bool,
            aprilTagBindings: [UUID: [Int]],
            aprilTagStaleTimeout: Double,
            openness: BinOpennessInputs
        ) {
            let snapshot = PipelineInputs(
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
            inputsLock.lock()
            _inputs = snapshot
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
            depositDetector.requiredDwellFrames = inputs.dwellFrames
            depositDetector.reacquireGrace = inputs.reacquireGrace
            depositDetector.throwFeedbackGrace = inputs.throwFeedbackGrace
            let usesTags = inputs.aprilTagEnabled && !inputs.openness.usesMarkers
            var tagFrame = usesTags
                ? aprilTagBinDetector.update(
                    zones: currentZones,
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
                    zones: currentZones,
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
            depositDetector.binOpenState = openness.openState(zones: currentZones)
            let zoneFrame = depositDetector.update(tracks: tracked, zones: currentZones)
            if inputs.settings.pccJudgeEnabled {
                evaluatePCCJudgments(
                    deposits: zoneFrame.deposits,
                    tracked: tracked,
                    confirmationFrame: confirmationFrame,
                    originalImage: result.originalImage,
                    pipeline: inputs.settings.decisionPipeline,
                    confidentAuditEnabled: inputs.settings.pccConfidentAuditEnabled
                )
            }
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

        /// Samples color/texture priors for the largest boxes at most once per interval.
        /// Runs on the inference queue; the sampler is queue-owned state.
        private func sampleAppearancePriors(
            image: UIImage,
            boxes: [Box]
        ) -> [Int: AppearancePrior] {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastAppearanceSampleAt >= WasteSortConfig.defaultAppearanceInterval else {
                return [:]
            }
            lastAppearanceSampleAt = now
            // Bound the cost: the biggest items are the ones being sorted.
            let largest = boxes.sorted { $0.xywhn.width * $0.xywhn.height > $1.xywhn.width * $1.xywhn.height }
                .prefix(6)
            var priors: [Int: AppearancePrior] = [:]
            for box in largest {
                guard let prior = appearanceSampler
                    .sample(image: image, rectNorm: box.xywhn)
                    .map({ AppearanceAnalyzer.prior(for: $0) })
                else { continue }
                priors[box.index] = prior
            }
            return priors
        }

        /// Fires zoom re-checks for tracks that have been unsure and still for long
        /// enough. Inference-queue owned state; completion lands on the engine's queue.
        private func requestRechecks(
            for tracked: [TrackedDetection],
            image: UIImage,
            settings: RuntimeSettings
        ) {
            let now = CFAbsoluteTimeGetCurrent()
            for track in tracked where track.beliefUncertain {
                guard zoomRecheck.shouldRecheck(
                    track: track,
                    timestamp: now,
                    delay: WasteSortConfig.defaultRecheckDelay,
                    cooldown: WasteSortConfig.defaultRecheckCooldown,
                    maxDriftPerFrame: 0.05
                ) else { continue }
                zoomRecheck.request(
                    image: image,
                    boxNorm: track.displayXywhn,
                    trackID: track.id,
                    modelName: settings.selectedModelName,
                    settings: settings
                ) { [weak self] outcome in
                    guard let self, let outcome else { return }
                    self.recheckBufferLock.lock()
                    self.pendingRecheckOutcomes.append(outcome)
                    self.recheckBufferLock.unlock()
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
                    pccJudge.arbitrate(context, crop: cropsByTrack[deposit.trackID])
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

        /// Applies buffered re-check verdicts to the tracker. Must run on the inference
        /// queue — this is why outcomes buffer instead of injecting directly.
        private func drainRecheckOutcomes() {
            recheckBufferLock.lock()
            let outcomes = pendingRecheckOutcomes
            pendingRecheckOutcomes.removeAll(keepingCapacity: true)
            recheckBufferLock.unlock()
            guard !outcomes.isEmpty else { return }
            let now = CFAbsoluteTimeGetCurrent()
            for outcome in outcomes {
                tracker.injectRecheck(
                    trackID: outcome.trackID,
                    classKey: outcome.classKey,
                    className: outcome.className,
                    conf: outcome.conf,
                    weight: Float(WasteSortConfig.defaultRecheckWeight) * outcome.conf,
                    at: now
                )
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
                },
                center.addObserver(
                    forName: UIDevice.orientationDidChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    // YOLOView writes both connections on its camera queue first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self?.syncInferenceOrientation()
                    }
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
                syncInferenceOrientation()
                return true
            }

            let ok = YOLOViewCameraSwitcher.switchTo(device, in: view)
            if ok {
                applyCaptureResolution(force: true)
                lastAppliedCaptureDeviceID = nil
                registerCaptureSessionIfNeeded()
                applyCaptureControlsIfNeeded()
                installFrameColorProxyIfNeeded()
                syncInferenceOrientation()
            }
            return ok
        }

        private func syncInferenceOrientation() {
            guard let view = yoloView else { return }
            let delta = YOLOViewCameraSwitcher.syncInferenceOrientation(in: view)
            guard lastPresentationDelta != delta else { return }
            lastPresentationDelta = delta
            DispatchQueue.main.async { [weak self] in
                self?.onPresentationDelta?(delta)
            }
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
                let inputs = self.currentInputs
                if inputs.openness.usesMarkers {
                    // Marker detection reads chroma, so it has to run on the buffer as the
                    // sensor delivered it — before `FrameColorAdjuster` rewrites it below.
                    var config = BinMarkerConfig.standard
                    config.style = inputs.openness.markerKind.style
                    var dashConfig = BinMarkerDashConfig.standard
                    dashConfig.profile = inputs.openness.markerDashProfile
                    dashConfig.shape = inputs.openness.markerKind.shape
                    // After both, which recompute it from what they were measured to need.
                    dashConfig.minRuns = BinMarkerDashConfig
                        .runs(forDashes: inputs.openness.markerDashesToOpen)
                    self.markerPipeline.apply(config: config, dashConfig: dashConfig,
                                              inks: inputs.openness.markerInks)
                    self.markerPipeline.submit(pixelBuffer)
                } else if inputs.aprilTagEnabled {
                    self.aprilTagPipeline.submit(pixelBuffer)
                }
                if inputs.settings.barcodeAssistEnabled {
                    self.barcodeScanner.submit(pixelBuffer)
                }
            }
            aprilTagPipeline.onTags = { [weak self] tags, timestamp in
                self?.aprilTagBinDetector.ingest(tags: tags, timestamp: timestamp)
            }
            markerPipeline.onDetections = { [weak self] detections, timestamp in
                self?.markerBinDetector.ingest(detections: detections, timestamp: timestamp)
            }
            markerPipeline.onDashRows = { [weak self] rows, timestamp in
                self?.markerBinDetector.ingest(rows: rows, timestamp: timestamp)
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
            zoomRecheck.invalidateModel()
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
    var throwFeedbackGrace: Double
    var aprilTagEnabled: Bool
    var aprilTagBindings: [UUID: [Int]]
    var aprilTagStaleTimeout: Double
    var openness: BinOpennessInputs = BinOpennessInputs()
}

/// The marker half of the lid signal, grouped so adding to it does not widen four
/// initialisers every time.
struct BinOpennessInputs: Equatable, Sendable {
    var source: BinOpennessSource = .aprilTag
    /// What is printed on the strips. Carries both the detection style and the dash shape,
    /// because on site they are not two decisions.
    var markerKind: BinMarkerKind = .dashes
    var markerDashProfile: BinMarkerDashProfile = .thin
    /// Printed dashes that must clear the counter edge before the bin reads open.
    var markerDashesToOpen: Int = BinMarkerDashProfile.thin.dashesNeeded
    var markerStaleTimeout: Double = BinMarkerStateConfig.standard.staleTimeout
    /// Palette with any on-site calibration already folded in.
    var markerInks: [BinMarkerInk] = BinMarkerInk.all
    var markerDebugOverlay: Bool = false

    var usesMarkers: Bool { source == .marker }
}
