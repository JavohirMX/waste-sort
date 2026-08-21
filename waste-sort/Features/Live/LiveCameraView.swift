import AVFoundation
import SwiftUI
import UIKit
import UltralyticsYOLO

struct LiveCameraView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var history: ZoneEventHistoryStore
    @EnvironmentObject private var verdictLog: FoundationVerdictLog
    @EnvironmentObject private var aprilTagStore: AprilTagBindingStore
    @State private var counts: [String: Int] = [:]
    @State private var fps = 0
    @State private var tracks: [TrackedDetection] = []
    @State private var detectedTags: [TrackedAprilTag] = []
    @State private var tagStatuses: [UUID: BinOpenness] = [:]
    @State private var tagStats: AprilTagFrameStats?
    @State private var imageSize: CGSize = .zero
    @State private var fpsMonitor = FrameRateMonitor()
    @State private var showSettings = false
    @State private var selectedZoneID: UUID?
    @State private var flashedZoneIDs: Set<UUID> = []
    @State private var occupiedZoneIDs: Set<UUID> = []
    @State private var armedZoneIDs: Set<UUID> = []
    @State private var settlingZoneIDs: Set<UUID> = []
    @State private var confirmationFrame = ConfirmationFrame()
    @State private var freshDepositID: UUID?
    @State private var showHistory = false
    @State private var segmentFrames: [String: CGRect] = [:]

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
                        aprilTagRangeProfile: aprilTagStore.rangeProfile,
                        foundationConfirmationEnabled: settings.foundationConfirmationEnabled
                    ) { result, tracked, zoneFrame, tagFrame, confirmed, verdicts in
                        if let measured = fpsMonitor.tick(reportedFPS: result.fps) {
                            fps = measured
                        }
                        imageSize = result.orig_shape
                        tracks = tracked
                        if confirmationFrame != confirmed {
                            confirmationFrame = confirmed
                        }
                        if !verdicts.isEmpty {
                            verdictLog.append(verdicts)
                        }
                        detectedTags = tagFrame.detectedTags
                        tagStatuses = tagFrame.statuses
                        tagStats = tagFrame.detectorStats
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
                        style: settings.boxOverlayStyle,
                        confirmation: confirmationFrame
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
                    CategoryBar(counts: counts, ctaStyle: settings.ctaStyle)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.categoryBarTopGap)
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
                    if settings.foundationConfirmationEnabled, settings.foundationVerdictLogEnabled {
                        FoundationVerdictStrip(
                            records: verdictLog.records,
                            onClear: { verdictLog.clear() }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.hudInset)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                        .animation(
                            .easeOut(duration: Theme.animationDuration),
                            value: verdictLog.records.first?.id
                        )
                    }

                    HStack(alignment: .bottom) {
                        if let last = history.events.first {
                            LastDepositChip(
                                record: last,
                                isFresh: freshDepositID == last.id,
                                onTap: { showHistory = true }
                            )
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .id(last.id)
                        }
                        Spacer(minLength: 0)
                        fpsBadge
                    }
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.7),
                        value: history.events.first?.id
                    )
                    .animation(.easeOut(duration: Theme.animationDuration), value: freshDepositID)
                    .padding(.horizontal, Theme.hudInset)
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
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environmentObject(history)
                .environmentObject(zoneStore)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(recording)
                .environmentObject(zoneStore)
                .environmentObject(history)
                .environmentObject(aprilTagStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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

    /// Flashes the receiving zone outline and pops the last-deposit chip.
    private func flash(_ deposits: [ZoneDeposit]) {
        let zoneIDs = Set(deposits.map(\.zoneID))
        let latest = history.events.first?.id
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            flashedZoneIDs.formUnion(zoneIDs)
            freshDepositID = latest
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                flashedZoneIDs.subtract(zoneIDs)
                if freshDepositID == latest { freshDepositID = nil }
            }
        }
    }

    private var fpsBadge: some View {
        Text("\(fps) FPS")
            .font(.system(.caption2, design: .default).weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
            .accessibilityLabel("\(fps) frames per second")
            .accessibilityAction(named: "Open settings") {
                showSettings = true
            }
            .onLongPressGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showSettings = true
            }
    }
}

/// Smoothed pipeline FPS from callback timing; prefers the model's reported rate when present.
private final class FrameRateMonitor {
    private var lastFrameAt: CFAbsoluteTime = 0
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
    var foundationConfirmationEnabled: Bool
    var onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, AprilTagStatusFrame, ConfirmationFrame, [FoundationVerdictRecord]) -> Void)?

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
            foundationConfirmationEnabled: foundationConfirmationEnabled,
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
        applyTracking(context.coordinator, settings: settings)
        applyZones(context.coordinator)
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
        context.coordinator.recording = recording
        context.coordinator.aprilTagEnabled = aprilTagEnabled
        context.coordinator.aprilTagBindings = aprilTagBindings
        context.coordinator.aprilTagRangeProfile = aprilTagRangeProfile
        applyThresholds(uiView, settings: settings)
        applyTracking(context.coordinator, settings: settings)
        applyZones(context.coordinator)
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
        coordinator.applyCaptureControlsIfNeeded()
        coordinator.updateFrameColorControls()
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

    private func applyTracking(_ coordinator: Coordinator, settings: RuntimeSettings) {
        coordinator.settings = settings
        coordinator.tracker.iouThreshold = CGFloat(settings.trackerIou)
        coordinator.tracker.confirmHits = settings.confirmHits
        coordinator.tracker.maxMisses = settings.maxMisses
        coordinator.tracker.crossClassIouThreshold = CGFloat(settings.crossClassIou)
        coordinator.tracker.classLockWindow = settings.classLockWindow
        coordinator.tracker.emaAlpha = CGFloat(settings.emaAlpha)
        coordinator.tracker.boxInflate = CGFloat(settings.boxInflate)
        coordinator.tracker.maxSpeed = CGFloat(settings.maxSpeed)
    }

    private func applyZones(_ coordinator: Coordinator) {
        coordinator.zones = zones
        coordinator.depositDetector.requiredDwellFrames = dwellFrames
        coordinator.depositDetector.reacquireGrace = reacquireGrace
        coordinator.aprilTagStaleTimeout = aprilTagStaleTimeout
        coordinator.setConfirmationEnabled(foundationConfirmationEnabled)
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
        var onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, AprilTagStatusFrame, ConfirmationFrame, [FoundationVerdictRecord]) -> Void)?
        var settings: RuntimeSettings
        var preferredCameraID: String
        var selectedModelName: String
        var recording: RecordingController
        var zones: [DropZone]
        var aprilTagEnabled: Bool
        var aprilTagBindings: [UUID: [Int]]
        var aprilTagStaleTimeout: Double
        var aprilTagRangeProfile: AprilTagRangeProfile = .far {
            didSet {
                guard oldValue != aprilTagRangeProfile else { return }
                aprilTagPipeline.apply(tuning: aprilTagRangeProfile.tuning)
                aprilTagPipeline.reset()
                applyCaptureResolution(force: true)
            }
        }
        weak var yoloView: YOLOView?
        let tracker = DetectionTracker()
        let depositDetector = ZoneDepositDetector()
        let confirmation = CategoryConfirmationCoordinator(service: FoundationCategoryConfirmer())
        /// Resolved once: the answer involves a `dlsym` sweep and a system model query, and
        /// `applyZones` runs on every SwiftUI refresh — which is every detection frame.
        private lazy var isConfirmationSupported = FoundationCategoryAvailability.current.isReady
        let aprilTagPipeline = AprilTagFramePipeline(
            detector: AprilTagDetector(familyName: "tag16h5", tuning: AprilTagRangeProfile.far.tuning)
        )
        let aprilTagBinDetector = AprilTagBinStateDetector()
        private var cameraObservers: [NSObjectProtocol] = []
        private var applyWorkItem: DispatchWorkItem?
        private var isReloadingModel = false
        var capturingOriginals = false
        private var lastAppliedCaptureDeviceID: String?
        private var lastAppliedCaptureControls: CameraCaptureControls?
        private var frameColorProxy: VideoFrameColorProxy?

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
            foundationConfirmationEnabled: Bool,
            onDetection: ((YOLOResult, [TrackedDetection], ZoneFrameResult, AprilTagStatusFrame, ConfirmationFrame, [FoundationVerdictRecord]) -> Void)?
        ) {
            self.settings = settings
            self.preferredCameraID = preferredCameraID
            self.selectedModelName = selectedModelName
            self.recording = recording
            self.zones = zones
            self.aprilTagEnabled = aprilTagEnabled
            self.aprilTagBindings = aprilTagBindings
            self.aprilTagStaleTimeout = aprilTagStaleTimeout
            self.aprilTagRangeProfile = aprilTagRangeProfile
            self.onDetection = onDetection
            aprilTagPipeline.apply(tuning: aprilTagRangeProfile.tuning)
            depositDetector.requiredDwellFrames = dwellFrames
            depositDetector.reacquireGrace = reacquireGrace
            setConfirmationEnabled(foundationConfirmationEnabled)
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
            if let view = yoloView {
                view.setConfidenceThreshold(settings.confidence)
                view.setIouThreshold(settings.iou)
                view.setNumItemsThreshold(settings.maxItems)
                // The confirmation layer needs real pixels to crop, so it turns frame
                // capture on for itself the same way recording does.
                let shouldCapture = recording.shouldCaptureOriginalFrames || confirmation.isEnabled
                if capturingOriginals != shouldCapture {
                    capturingOriginals = shouldCapture
                    YOLOViewPredictorAccess.setCapturesOriginalImage(shouldCapture, in: view)
                }
            }
            let minConf = Float(settings.confidence)
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
            // Everything downstream — boxes, the category bar, the CTA, deposits, the log —
            // reads the confirmed labels, because a verdict nobody acts on is decoration.
            let (tracked, confirmationFrame, verdictRecords) = confirmation.update(
                tracks: tracker.update(raw),
                frameImage: { result.originalImage.flatMap(UprightFrameImage.cgImage(from:)) }
            )
            let currentZones = zones
            var tagFrame = aprilTagEnabled
                ? aprilTagBinDetector.update(
                    zones: currentZones,
                    tagBindings: aprilTagBindings,
                    config: AprilTagConfig(staleTimeout: aprilTagStaleTimeout)
                )
                : AprilTagStatusFrame()
            if aprilTagEnabled {
                tagFrame.detectorStats = aprilTagPipeline.detector.lastFrameStats
            }
            depositDetector.binOpenState = FrameBinOpenState(tagFrame: tagFrame, zones: currentZones)
            let zoneFrame = depositDetector.update(tracks: tracked, zones: currentZones)
            if recording.isRecording {
                let fps = result.fps.flatMap { $0.isFinite ? Int($0.rounded()) : nil } ?? 0
                recording.ingestLiveFrame(
                    tracks: tracked,
                    deposits: zoneFrame.deposits,
                    originalImage: result.originalImage,
                    fps: fps,
                    settings: settings
                )
            }
            // Zone results ride the existing main-thread hop so the @Published history
            // append never happens off-main.
            DispatchQueue.main.async {
                self.onDetection?(
                    result,
                    tracked,
                    zoneFrame,
                    tagFrame,
                    confirmationFrame,
                    verdictRecords
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
            frameColorProxy?.controls = settings.frameColor
            frameColorProxy?.syncPreviewLayout()
        }

        func installFrameColorProxyIfNeeded() {
            guard let view = yoloView else { return }
            if frameColorProxy == nil {
                frameColorProxy = VideoFrameColorProxy()
            }
            // The tap copies luma here on the camera queue and detects on the pipeline's own
            // queue. Running the pass inline would cost YOLO an inference frame per detection.
            frameColorProxy?.frameTap = { [weak self] pixelBuffer in
                guard let self, self.aprilTagEnabled else { return }
                self.aprilTagPipeline.submit(pixelBuffer)
            }
            aprilTagPipeline.onTags = { [weak self] tags, timestamp in
                self?.aprilTagBinDetector.ingest(tags: tags, timestamp: timestamp)
            }
            frameColorProxy?.controls = settings.frameColor
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
            let controls = settings.captureControls
            if lastAppliedCaptureDeviceID == device.uniqueID,
               lastAppliedCaptureControls == controls
            {
                return
            }
            CameraCaptureAdjuster.apply(controls, to: device)
            lastAppliedCaptureDeviceID = device.uniqueID
            lastAppliedCaptureControls = controls
        }

        func registerCaptureSessionIfNeeded() {
            guard let view = yoloView else { return }
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
                        view.setConfidenceThreshold(self.settings.confidence)
                        view.setIouThreshold(self.settings.iou)
                        view.setNumItemsThreshold(self.settings.maxItems)
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
