import AVFoundation
import SwiftUI
import UIKit
import UltralyticsYOLO

struct LiveCameraView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var history: ZoneEventHistoryStore
    @EnvironmentObject private var aprilTagStore: AprilTagBindingStore
    @EnvironmentObject private var binStyle: BinStyleStore
    @State private var counts: [String: Int] = [:]
    @State private var fps = 0
    @State private var tracks: [TrackedDetection] = []
    @State private var detectedTags: [TrackedAprilTag] = []
    @State private var tagStatuses: [UUID: BinOpenness] = [:]
    @State private var tagStats: AprilTagFrameStats?
    @State private var imageSize: CGSize = .zero
    @State private var fpsMonitor = FrameRateMonitor()
    @State private var showSettings = false
    @State private var showStats = false
    @State private var selectedZoneID: UUID?
    @State private var flashedZoneIDs: Set<UUID> = []
    @State private var flashTask: Task<Void, Never>?
    @State private var occupiedZoneIDs: Set<UUID> = []
    @State private var armedZoneIDs: Set<UUID> = []
    @State private var settlingZoneIDs: Set<UUID> = []
    @State private var segmentFrames: [String: CGRect] = [:]
    @State private var detectedTagFailure: String?

    /// Non-nil while the AprilTag detector failed to initialize - lid gating is inert.
    private var tagFailureReason: String? {
        guard aprilTagStore.isEnabled else { return nil }
        return detectedTagFailure
    }

    private var activeBinIDs: Set<String> {
        Set(counts.compactMap { key, value in
            value > 0 ? key : nil
        })
    }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let coverScale = DetectionGeometry.coverScale(
                    for: settings.liveRotation,
                    viewSize: geo.size
                )
                let geoOrigin = geo.frame(in: .named(CTASpace.name)).origin
                let cameraSegmentFrames = Dictionary(
                    uniqueKeysWithValues: segmentFrames.map { id, rect in
                        (id, CTALayout.convert(rect, from: geoOrigin))
                    }
                )
                let cues = settings.ctaStyle == .arrows
                    ? CTACueMapper.cues(
                        from: tracks,
                        imageSize: imageSize,
                        viewSize: geo.size,
                        rotation: settings.liveRotation,
                        mirror: settings.liveMirror
                    )
                    : []
                let highlightBottom = CTALayout.barBottom(
                    from: cameraSegmentFrames,
                    fallback: Theme.categoryBarTopGap + Theme.barHeight - geoOrigin.y
                )
                ZStack {
                    // Rotate/mirror only the camera pixels; boxes stay upright and are remapped below.
                    LiveYOLOCamera(
                        settings: settings.runtime,
                        preferredCameraID: settings.preferredCameraID,
                        selectedModelName: settings.selectedModelName,
                        recording: recording,
                        zones: zoneStore.zones,
                        dwellFrames: zoneStore.dwellFrames,
                        reacquireGrace: zoneStore.reacquireGrace,
                        aprilTagEnabled: aprilTagStore.isEnabled,
                        aprilTagBindings: aprilTagStore.bindings,
                        aprilTagStaleTimeout: aprilTagStore.staleTimeout,
                        aprilTagRangeProfile: aprilTagStore.rangeProfile
                    ) { result, tracked, zoneFrame, tagFrame in
                        if let measured = fpsMonitor.tick(reportedFPS: result.fps) {
                            fps = measured
                        }
                        imageSize = result.orig_shape
                        tracks = tracked
                        detectedTags = tagFrame.detectedTags
                        tagStatuses = tagFrame.statuses
                        tagStats = tagFrame.detectorStats
                        detectedTagFailure = tagFrame.detectorFailureReason
                        if occupiedZoneIDs != zoneFrame.occupiedZoneIDs {
                            occupiedZoneIDs = zoneFrame.occupiedZoneIDs
                        }
                        if armedZoneIDs != zoneFrame.armedZoneIDs {
                            armedZoneIDs = zoneFrame.armedZoneIDs
                        }
                        if settlingZoneIDs != zoneFrame.settlingZoneIDs {
                            settlingZoneIDs = zoneFrame.settlingZoneIDs
                        }
                        if !zoneFrame.deposits.isEmpty {
                            history.append(zoneFrame.deposits)
                            flash(zoneFrame.deposits)
                        }

                        var nextCounts: [String: Int] = [:]
                        for track in tracked where !track.isCoasting {
                            let binID = BinGuide.info(for: track.classKey).id
                            guard binID != BinGuide.unknown.id else { continue }
                            nextCounts[binID, default: 0] += 1
                        }
                        if nextCounts != counts {
                            counts = nextCounts
                        }
                    }
                    .scaleEffect(x: settings.liveMirror ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(settings.liveRotation.degrees))
                    .scaleEffect(coverScale)

                    ZoneOverlayView(
                        zones: zoneStore.zones,
                        imageSize: imageSize,
                        viewSize: geo.size,
                        rotation: settings.liveRotation,
                        mirror: settings.liveMirror,
                        isEditing: zoneStore.isEditingZones,
                        showZones: settings.showZoneOverlay,
                        selectedZoneID: selectedZoneID,
                        flashedZoneIDs: flashedZoneIDs,
                        occupiedZoneIDs: occupiedZoneIDs,
                        armedZoneIDs: armedZoneIDs,
                        settlingZoneIDs: settlingZoneIDs,
                        onMoveCorner: moveCorner,
                        onMoveZone: moveZone,
                        onSelectZone: { selectedZoneID = $0 }
                    )

                    if aprilTagStore.isEnabled, aprilTagStore.showDebugOverlay {
                        AprilTagDebugOverlay(
                            detectedTags: detectedTags,
                            statuses: tagStatuses,
                            zones: zoneStore.zones,
                            imageSize: imageSize,
                            viewSize: geo.size,
                            rotation: settings.liveRotation,
                            mirror: settings.liveMirror,
                            stats: tagStats
                        )
                    }

                    if !zoneStore.isEditingZones, settings.ctaStyle == .highlightSection {
                        CTAHighlightOverlay(
                            activeBinIDs: activeBinIDs,
                            viewSize: geo.size,
                            barBottom: highlightBottom
                        )
                    }

                    DetectionBoxOverlay(
                        tracks: tracks,
                        imageSize: imageSize,
                        viewSize: geo.size,
                        useAspectFill: true,
                        rotation: settings.liveRotation,
                        mirror: settings.liveMirror,
                        style: settings.boxOverlayStyle
                    )
                    .allowsHitTesting(false)

                    if !zoneStore.isEditingZones, settings.ctaStyle == .arrows {
                        CTAArrowOverlay(cues: cues, segmentFrames: cameraSegmentFrames)
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(zoneStore.isEditingZones)

            VStack(spacing: 0) {
                // The top stays clear while calibrating so nothing covers a zone.
                if !zoneStore.isEditingZones {
                    CategoryBar(
                        bins: binStyle.orderedBins,
                        counts: counts,
                        ctaStyle: settings.ctaStyle
                    )
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.categoryBarTopGap)

                    if let tagFailure = tagFailureReason {
                        TagFailureBanner(reason: tagFailure)
                            .padding(.horizontal, Theme.hudInset)
                            .padding(.top, 6)
                    }
                }

                Spacer(minLength: 0)

                if zoneStore.isEditingZones {
                    ZoneEditBar(
                        zones: zoneStore.zones,
                        selectedZoneID: $selectedZoneID,
                        onReset: {
                            zoneStore.resetToDefaults(
                                rotation: settings.liveRotation,
                                mirror: settings.liveMirror
                            )
                        },
                        onDone: { zoneStore.isEditingZones = false }
                    )
                    .padding(.horizontal, Theme.hudInset)
                    .padding(.bottom, Theme.hudInset)
                } else {
                    HStack(alignment: .bottom) {
                        if settings.showFPS {
                            Text("\(fps) FPS")
                                .font(.system(.caption, design: .default).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                                .accessibilityLabel("\(fps) frames per second")
                                .padding(.leading, Theme.hudInset)
                        }
                        Spacer(minLength: 0)
                        statsGlassButton
                    }
                    .padding(.bottom, Theme.hudInset)
                }
            }
        }
        .environment(\.hudTextScale, CGFloat(settings.hudTextScale))
        .coordinateSpace(name: CTASpace.name)
        .overlay {
            if !zoneStore.isEditingZones, settings.ctaStyle == .dropdown {
                CTADropdownOverlay(activeBinIDs: activeBinIDs, segmentFrames: segmentFrames)
            }
        }
        .onPreferenceChange(CategorySegmentFramesKey.self) { segmentFrames = $0 }
        .onChange(of: zoneStore.isEditingZones) { _, editing in
            selectedZoneID = editing ? zoneStore.zones.first?.id : nil
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(recording)
                .environmentObject(zoneStore)
                .environmentObject(history)
                .environmentObject(aprilTagStore)
                .environmentObject(BinStyleStore.shared)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .overlay {
            if showStats {
                StatsView(onClose: {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showStats = false
                    }
                })
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(binStyle)
                .environmentObject(zoneStore)
                .background(.clear)
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showStats)
    }

    private func moveCorner(zoneID: UUID, index: Int, point: CGPoint) {
        guard var zone = zoneStore.zones.first(where: { $0.id == zoneID }),
              zone.corners.indices.contains(index)
        else { return }
        zone.corners[index] = point
        zoneStore.update(zone)
    }

    private func moveZone(zoneID: UUID, corners: [CGPoint]) {
        guard var zone = zoneStore.zones.first(where: { $0.id == zoneID }) else { return }
        zone.corners = corners
        zoneStore.update(zone)
    }

    /// Flashes the receiving zone outline on a confirmed deposit.
    private func flash(_ deposits: [ZoneDeposit]) {
        let zoneIDs = Set(deposits.map(\.zoneID))
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            flashedZoneIDs.formUnion(zoneIDs)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                flashedZoneIDs.subtract(zoneIDs)
            }
        }
    }

    private var statsGlassButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                showStats = true
            }
        } label: {
            GlassChrome.edgeTabLabel(edge: .trailing) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Waste stats")
        .accessibilityHint("Opens stats. Long press opens developer settings.")
        .accessibilityAction(named: "Open developer settings") {
            showSettings = true
        }
        .onLongPressGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showSettings = true
        }
    }
}

/// Warning chip shown when the AprilTag detector could not initialize: lid gating
/// silently degrades to "bins always closed" unless the operator is told.
private struct TagFailureBanner: View {
    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Bin lid tracking unavailable - deposits count regardless of lids. (\(reason))")
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

/// Smoothed pipeline FPS from callback timing; prefers the model's reported rate when present.
private final class FrameRateMonitor {    private var lastFrameAt: CFAbsoluteTime = 0
    private var ema: Double = 0
    private(set) var fps: Int = 0

    func tick(reportedFPS: Double?) -> Int? {
        let now = CFAbsoluteTimeGetCurrent()
        let instant: Double
        if let reportedFPS, reportedFPS.isFinite, reportedFPS > 0 {
            instant = reportedFPS
        } else if lastFrameAt > 0 {
            let dt = now - lastFrameAt
            guard dt > 0, dt < 2 else {
                lastFrameAt = now
                return nil
            }
            instant = 1.0 / dt
        } else {
            lastFrameAt = now
            return nil
        }
        lastFrameAt = now
        ema = ema == 0 ? instant : ema * 0.85 + instant * 0.15
        let rounded = max(0, Int(ema.rounded()))
        guard rounded != fps else { return nil }
        fps = rounded
        return rounded
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

/// YOLOCamera wrapper that loads the selected segment model, sets thresholds, and hides developer chrome.
private struct LiveYOLOCamera: UIViewRepresentable {
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
        applyThresholds(view, settings: settings)
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
        applyThresholds(uiView, settings: settings)
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

    private func applyThresholds(_ view: YOLOView, settings: RuntimeSettings) {
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
            tracker.classLockWindow = inputs.settings.classLockWindow
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
                guard let self, self.currentInputs.aprilTagEnabled else { return }
                self.aprilTagPipeline.submit(pixelBuffer)
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
                        view.setConfidenceThreshold(self.currentInputs.settings.confidence)
                        view.setIouThreshold(self.currentInputs.settings.iou)
                        view.setNumItemsThreshold(self.currentInputs.settings.maxItems)
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
