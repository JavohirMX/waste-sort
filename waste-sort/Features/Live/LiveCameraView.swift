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
    @EnvironmentObject private var markerStore: BinMarkerStore
    @EnvironmentObject private var binStyle: BinStyleStore
    @EnvironmentObject private var binPreview: BinPreviewCoordinator
    @State private var counts: [String: Int] = [:]
    @State private var fps = 0
    @State private var tracks: [TrackedDetection] = []
    @State private var detectedTags: [TrackedAprilTag] = []
    @State private var tagStatuses: [UUID: BinOpenness] = [:]
    @State private var tagStats: AprilTagFrameStats?
    @State private var markerFrame = BinMarkerStatusFrame()
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
    @State private var confirmationFrame = ConfirmationFrame()
    @State private var freshDepositID: UUID?
    @State private var freshVerdictID: UUID?
    @State private var showVerdicts = false
    @State private var showHistory = false
    @State private var segmentFrames: [String: CGRect] = [:]
    @State private var detectedTagFailure: String?
    @State private var barcodeHint: ScannedBarcode?
    @State private var barcodeClearTask: Task<Void, Never>?
    @State private var throwFeedbackGate = ThrowFeedbackGate()
    @State private var previewedFeedbackIDs: Set<UUID> = []
    @State private var presentationDelta: LivePreviewRotation = .zero

    /// Overlay mapping includes any leftover preview-vs-buffer rotation; the
    /// camera view itself only uses the operator's `liveRotation`.
    private var overlayRotation: LivePreviewRotation {
        VideoRotationMath.composed(settings.liveRotation, presentationDelta)
    }

    /// Non-nil while the AprilTag detector failed to initialize - lid gating is inert.
    private var tagFailureReason: String? {
        guard !settings.demoMode, aprilTagStore.isEnabled else { return nil }
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
                        rotation: overlayRotation,
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
                        throwFeedbackGrace: zoneStore.throwFeedbackGrace,
                        aprilTagEnabled: aprilTagStore.isEnabled,
                        aprilTagBindings: aprilTagStore.bindings,
                        aprilTagStaleTimeout: aprilTagStore.staleTimeout,
                        aprilTagRangeProfile: aprilTagStore.rangeProfile,
                        openness: BinOpennessInputs(
                            source: markerStore.source,
                            markerKind: markerStore.kind,
                            markerDashProfile: markerStore.dashProfile,
                            markerDashesToOpen: markerStore.dashesToOpen,
                            markerStaleTimeout: markerStore.staleTimeout,
                            markerInks: markerStore.inks,
                            markerDebugOverlay: markerStore.showDebugOverlay,
                            forceOpen: settings.demoMode
                        ),
                        foundationConfirmationEnabled: settings.foundationConfirmationEnabled,
                        onPresentationDelta: { delta in
                            if presentationDelta != delta {
                                presentationDelta = delta
                            }
                        },
                        onBarcodeHint: { barcode in
                            barcodeClearTask?.cancel()
                            barcodeHint = barcode
                            guard barcode != nil else { return }
                            barcodeClearTask = Task {
                                try? await Task.sleep(for: .seconds(4))
                                guard !Task.isCancelled else { return }
                                barcodeHint = nil
                            }
                        },
                        onDetection: { result, tracked, zoneFrame, openness, confirmed, verdicts in
                        let tagFrame = openness.tag
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
                            flashVerdict()
                        }
                        detectedTags = tagFrame.detectedTags
                        tagStatuses = tagFrame.statuses
                        tagStats = tagFrame.detectorStats
                        detectedTagFailure = tagFrame.detectorFailureReason
                        if markerFrame != openness.marker {
                            markerFrame = openness.marker
                        }
                        if occupiedZoneIDs != zoneFrame.occupiedZoneIDs {
                            occupiedZoneIDs = zoneFrame.occupiedZoneIDs
                        }
                        if armedZoneIDs != zoneFrame.armedZoneIDs {
                            armedZoneIDs = zoneFrame.armedZoneIDs
                        }
                        if settlingZoneIDs != zoneFrame.settlingZoneIDs {
                            settlingZoneIDs = zoneFrame.settlingZoneIDs
                        }
                        if !zoneFrame.cancelledThrowFeedbackIDs.isEmpty {
                            cancelThrowFeedback(ids: zoneFrame.cancelledThrowFeedbackIDs)
                        }
                        for cue in zoneFrame.throwFeedbackCues {
                            presentThrowFeedback(cue)
                        }
                        if !zoneFrame.deposits.isEmpty {
                            history.append(zoneFrame.deposits)
                            flash(zoneFrame.deposits)
                        }

                        var nextCounts: [String: Int] = [:]
                        for track in tracked where !track.isCoasting {
                            // Unsure items light up the fallback bin so the bar stays honest;
                            // dirty recyclable lights residual and recyclable together.
                            let binIDs = track.beliefUncertain
                                ? [BinGuide.fallbackBinID]
                                : BinGuide.barBinIDs(for: track.classKey)
                            for binID in binIDs where binID != BinGuide.unknown.id {
                                nextCounts[binID, default: 0] += 1
                            }
                        }
                        if nextCounts != counts {
                            counts = nextCounts
                        }
                    }
                    )
                    .scaleEffect(x: settings.liveMirror ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(settings.liveRotation.degrees))
                    .scaleEffect(coverScale)

                    ZoneOverlayView(
                        zones: zoneStore.zones,
                        imageSize: imageSize,
                        viewSize: geo.size,
                        rotation: overlayRotation,
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

                    if !settings.demoMode, markerStore.source == .marker, markerStore.showDebugOverlay {
                        BinMarkerDebugOverlay(
                            frame: markerFrame,
                            zones: zoneStore.zones,
                            style: markerStore.style,
                            imageSize: imageSize,
                            viewSize: geo.size,
                            rotation: settings.liveRotation,
                            mirror: settings.liveMirror,
                            onCalibrate: calibrateMarkers
                        )
                    }

                    if !settings.demoMode, markerStore.source == .aprilTag, aprilTagStore.isEnabled, aprilTagStore.showDebugOverlay {
                        AprilTagDebugOverlay(
                            detectedTags: detectedTags,
                            statuses: tagStatuses,
                            zones: zoneStore.zones,
                            imageSize: imageSize,
                            viewSize: geo.size,
                            rotation: overlayRotation,
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
                        rotation: overlayRotation,
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

            if !binPreview.isActive {
                VStack {
                    Spacer()
                    ZStack(alignment: .bottom) {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .clear, location: 0.31),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                        .opacity(0.31)
                        Text("Separate waste items to help us identify them.")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.hudInset)
                            .padding(.bottom, Theme.hudInset)
                    }
                    .frame(height: 224)
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                // The top stays clear while calibrating so nothing covers a zone.
                if !zoneStore.isEditingZones {
                    CategoryBar(
                        bins: binStyle.orderedBins,
                        counts: counts,
                        ctaStyle: settings.ctaStyle,
                        throwFeedback: throwFeedbackGate.feedback,
                        throwFeedbackToken: throwFeedbackGate.token,
                        onTripleTap: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.easeInOut(duration: 0.35)) {
                                showSettings = true
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.top, Theme.categoryBarTopGap)

                if let tagFailure = tagFailureReason {
                    TagFailureBanner(reason: tagFailure)
                        .padding(.horizontal, Theme.hudInset)
                        .padding(.top, 6)
                }

                if let barcode = barcodeHint {
                    BarcodeHintChip(barcode: barcode)
                        .padding(.horizontal, Theme.hudInset)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                }

                Spacer(minLength: 0)

                if zoneStore.isEditingZones {
                    ZoneEditBar(
                        zones: zoneStore.zones,
                        selectedZoneID: $selectedZoneID,
                        onReset: {
                            zoneStore.resetToDefaults(
                                rotation: overlayRotation,
                                mirror: settings.liveMirror
                            )
                        },
                        onDone: { zoneStore.isEditingZones = false }
                    )
                    .padding(.horizontal, Theme.hudInset)
                    .padding(.bottom, Theme.hudInset)
                } else if binPreview.isActive {
                    binPreviewBar
                        .padding(.bottom, Theme.hudInset)
                } else {
                    HStack(alignment: .bottom) {
                        HStack(alignment: .bottom, spacing: 8) {
                            if settings.showFPS {
                                Text("\(fps) FPS")
                                    .font(.system(.caption, design: .default).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.7))
                                    .accessibilityLabel("\(fps) frames per second")
                            }
                            if settings.showLastDepositOnLive, let last = history.events.first {
                                LastDepositChip(
                                    record: last,
                                    isFresh: freshDepositID == last.id,
                                    onTap: { showHistory = true }
                                )
                                .transition(.move(edge: .leading).combined(with: .opacity))
                                .id(last.id)
                            }
                            if tracks.contains(where: {
                                !$0.isCoasting && BinGuide.isDirtyRecyclable($0.classKey)
                            }) {
                                DirtyRecyclableSuggestionChip()
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                            if settings.foundationConfirmationEnabled,
                               settings.foundationVerdictLogEnabled,
                               let verdict = verdictLog.records.first
                            {
                                LastVerdictChip(
                                    record: verdict,
                                    isFresh: freshVerdictID == verdict.id,
                                    onTap: { showVerdicts = true }
                                )
                                .transition(.move(edge: .leading).combined(with: .opacity))
                                .id(verdict.id)
                            }
                        }
                        .padding(.leading, Theme.hudInset)
                        Spacer(minLength: 0)
                        statsGlassButton
                    }
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.7),
                        value: tracks.contains(where: { $0.beliefUncertain })
                    )
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.7),
                        value: history.events.first?.id
                    )
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.7),
                        value: tracks.contains(where: {
                            !$0.isCoasting && BinGuide.isDirtyRecyclable($0.classKey)
                        })
                    )
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.7),
                        value: verdictLog.records.first?.id
                    )
                    .animation(.easeOut(duration: Theme.animationDuration), value: freshDepositID)
                    .animation(.easeOut(duration: Theme.animationDuration), value: freshVerdictID)
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
                .environmentObject(binStyle)
        }
        .sheet(isPresented: $showVerdicts) {
            VerdictHistoryView()
                .environmentObject(verdictLog)
        }
        .overlay {
            if showSettings {
                SettingsView(onClose: {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showSettings = false
                    }
                })
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }
        }
        .overlay {
            if showStats {
                StatsView(onClose: {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showStats = false
                    }
                })
                .environmentObject(binPreview)
                .background(.clear)
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showSettings)
        .animation(.easeInOut(duration: 0.35), value: showStats)
        .animation(.easeInOut(duration: 0.35), value: binPreview.isActive)
    }

    /// Writes down the chroma the camera is actually reporting for each visible strip.
    ///
    /// The palette ships with the chroma of ideal ink, which is not what comes back from a
    /// particular printer, under a particular lamp, through a particular camera's white
    /// balance. Widening the match tolerance to cover that gap would start admitting colored
    /// rubbish; measuring the real thing once does not.
    ///
    /// Only strips whose rhythm was fully read are learned from. A degraded reading was named
    /// by the very colour we would be storing, so learning from it would let the palette drift
    /// wherever the first mistake pointed.
    private func calibrateMarkers() {
        var learned = 0
        for detection in markerFrame.detections {
            guard !detection.isDegraded,
                  let slot = detection.slot(style: markerStore.style)
            else { continue }
            markerStore.calibrate(slot: slot.index, chroma: detection.chroma)
            learned += 1
        }
        guard learned > 0 else { return }
        HapticsService.shared.fire(.mediumImpact)
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

    /// Same beat as a deposit landing, minus the haptic — the model answers often enough
    /// that buzzing every time would be noise.
    private func flashVerdict() {
        let latest = verdictLog.records.first?.id
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            freshVerdictID = latest
        }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                if freshVerdictID == latest { freshVerdictID = nil }
            }
        }
    }

    /// Flashes the receiving zone outline on a confirmed deposit.
    private func flash(_ deposits: [ZoneDeposit]) {
        let zoneIDs = Set(deposits.map(\.zoneID))
        let latest = history.events.first?.id
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            flashedZoneIDs.formUnion(zoneIDs)
            freshDepositID = latest
        }
        announceAndVibrate(deposits)
        if let deposit = deposits.last {
            if previewedFeedbackIDs.contains(deposit.id) {
                releasePersistedFeedback(for: deposit)
            } else {
                presentThrowFeedback(
                    ThrowFeedbackCue(
                        objectID: deposit.id,
                        zoneBinID: deposit.zoneBinID,
                        isCorrect: deposit.isCorrect,
                        persistWhilePresent: false
                    )
                )
            }
            previewedFeedbackIDs.remove(deposit.id)
        }
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                flashedZoneIDs.subtract(zoneIDs)
                if freshDepositID == latest { freshDepositID = nil }
            }
        }
    }

    /// Overlays the destination segment; a newer throw cancels the dismiss.
    private func presentThrowFeedback(_ cue: ThrowFeedbackCue) {
        let feedback = ThrowFeedback.from(cue)
        if throwFeedbackGate.objectID == cue.objectID, throwFeedbackGate.feedback == feedback {
            return
        }
        var gate = throwFeedbackGate
        let token = gate.present(
            feedback,
            objectID: cue.objectID,
            persistWhilePresent: cue.persistWhilePresent
        )
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            throwFeedbackGate = gate
        }
        previewedFeedbackIDs.insert(cue.objectID)
        if settings.throwFeedbackSoundsEnabled {
            ThrowFeedbackPlayer.shared.play(correct: cue.isCorrect)
        }
        if !cue.persistWhilePresent {
            scheduleThrowFeedbackDismiss(token: token)
        }
    }

    private func cancelThrowFeedback(ids: Set<UUID>) {
        previewedFeedbackIDs.subtract(ids)
        guard let current = throwFeedbackGate.objectID, ids.contains(current) else { return }
        withAnimation(.easeOut(duration: Theme.animationDuration)) {
            throwFeedbackGate.dismiss(objectID: current)
        }
    }

    /// After a real deposit, an in-zone banner that was holding starts its 1.8s fade.
    private func releasePersistedFeedback(for deposit: ZoneDeposit) {
        guard throwFeedbackGate.objectID == deposit.id, throwFeedbackGate.persistWhilePresent else {
            return
        }
        let token = throwFeedbackGate.token
        var gate = throwFeedbackGate
        gate.markEphemeral()
        throwFeedbackGate = gate
        scheduleThrowFeedbackDismiss(token: token)
    }

    private func scheduleThrowFeedbackDismiss(token: UInt64) {
        Task {
            try? await Task.sleep(for: .seconds(Theme.throwFeedbackDuration))
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                throwFeedbackGate.dismissIfCurrent(token: token)
            }
        }
    }

    /// Spoken + tactile confirmation per deposit; hands-free kiosks rely on this.
    private func announceAndVibrate(_ deposits: [ZoneDeposit]) {
        var announcedBins = Set<String>()
        for deposit in deposits {
            if deposit.isCorrect {
                HapticsService.shared.fire(.depositCorrect(binID: deposit.zoneBinID))
            } else {
                HapticsService.shared.fire(.depositIncorrect)
            }
            guard settings.voiceGuidanceEnabled else { continue }
            let bin = BinGuide.info(for: deposit.classKey)
            guard bin != BinGuide.unknown, !announcedBins.contains(bin.id) else { continue }
            announcedBins.insert(bin.id)
            if deposit.wasUncertain {
                SpeechAnnouncer.shared.speak(
                    GuidancePhrases.uncertainDepositConfirmation(displayName: bin.displayName)
                )
            } else {
                SpeechAnnouncer.shared.speak(GuidancePhrases.depositConfirmation(displayName: bin.displayName))
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
        .accessibilityHint("Opens stats.")
    }

    /// Shown instead of the normal HUD row while previewing a Bin Settings change
    /// against the real camera feed.
    private var binPreviewBar: some View {
        ZStack {
            Text("This is a preview, save it to make it permanent.")
                .font(.system(size: 16, weight: .medium, design: .default))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)

            HStack {
                previewSettingsButton
                Spacer(minLength: 12)
                previewSaveButton
            }
        }
        .padding(.horizontal, Theme.hudInset)
    }

    private var previewSettingsButton: some View {
        previewPillButton(tint: .white.opacity(0.9)) {
            binPreview.isActive = false
            withAnimation(.easeInOut(duration: 0.35)) {
                showStats = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold, design: .default))
            }
            .foregroundStyle(Color.black)
        }
    }

    private var previewSaveButton: some View {
        previewPillButton(tint: Theme.onboardingAccent) {
            binPreview.isActive = false
            binPreview.returnsToBinSettings = false
        } label: {
            Text("Save")
                .font(.system(size: 17, weight: .bold, design: .default))
                .foregroundStyle(.white)
        }
    }

    /// A capsule that hugs its label instead of `GlassCapsuleButton`'s full-bleed
    /// `maxWidth: .infinity` sizing, for the compact Preview bar controls.
    private func previewPillButton<Content: View>(
        tint: Color,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(tint, in: Capsule(style: .continuous))
                .glassEffect(.clear.interactive(), in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
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
