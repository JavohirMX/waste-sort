import AVFoundation
import SwiftUI
import TipKit
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
    @State private var barcodeHint: ScannedBarcode?
    @State private var barcodeClearTask: Task<Void, Never>?

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
                        aprilTagRangeProfile: aprilTagStore.rangeProfile,
                        onBarcodeHint: { barcode in
                            barcodeClearTask?.cancel()
                            barcodeHint = barcode
                            guard barcode != nil else { return }
                            barcodeClearTask = Task {
                                try? await Task.sleep(for: .seconds(4))
                                guard !Task.isCancelled else { return }
                                barcodeHint = nil
                            }
                        }
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
                                .foregroundStyle(.white.opacity(0.9))
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
        announceAndVibrate(deposits)
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Theme.animationDuration)) {
                flashedZoneIDs.subtract(zoneIDs)
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
            SpeechAnnouncer.shared.speak(GuidancePhrases.depositConfirmation(displayName: bin.displayName))
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
            openSettings()
        }
        .onLongPressGesture {
            HapticsService.shared.fire(.lightTap)
            openSettings()
        }
        .popoverTip(SettingsAccessTip(), arrowEdge: .bottom) { _ in
            openSettings()
        }
    }

    private func openSettings() {
        showSettings = true
        Task { try? await SettingsAccessTip.Events.settingsOpenedViaLongPress.donate() }
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
