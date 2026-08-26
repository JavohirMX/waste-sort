import AVFoundation
import SwiftUI
import UIKit
import UltralyticsYOLO

struct LiveCameraView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var recording: RecordingController
    @EnvironmentObject var zoneStore: ZoneStore
    @EnvironmentObject var history: ZoneEventHistoryStore
    @EnvironmentObject var verdictLog: FoundationVerdictLog
    @EnvironmentObject var aprilTagStore: AprilTagBindingStore
    @EnvironmentObject var markerStore: BinMarkerStore
    @EnvironmentObject var binStyle: BinStyleStore
    @State var counts: [String: Int] = [:]
    @State var fps = 0
    @State var tracks: [TrackedDetection] = []
    @State var detectedTags: [TrackedAprilTag] = []
    @State var tagStatuses: [UUID: BinOpenness] = [:]
    @State var tagStats: AprilTagFrameStats?
    @State var markerFrame = BinMarkerStatusFrame()
    @State var imageSize: CGSize = .zero
    @State var fpsMonitor = FrameRateMonitor()
    @State var showSettings = false
    @State var showStats = false
    @State var selectedZoneID: UUID?
    @State var flashedZoneIDs: Set<UUID> = []
    @State var flashTask: Task<Void, Never>?
    @State var occupiedZoneIDs: Set<UUID> = []
    @State var armedZoneIDs: Set<UUID> = []
    @State var settlingZoneIDs: Set<UUID> = []
    @State var confirmationFrame = ConfirmationFrame()
    @State var freshDepositID: UUID?
    @State var freshVerdictID: UUID?
    @State var showVerdicts = false
    @State var showHistory = false
    @State var segmentFrames: [String: CGRect] = [:]
    @State var detectedTagFailure: String?
    @State var barcodeHint: ScannedBarcode?
    @State private var barcodeClearTask: Task<Void, Never>?
    @State var lastDropNotice: DepositDrop?
    @State var dropNoticeClearTask: Task<Void, Never>?
    @State var throwFeedbackGate = ThrowFeedbackGate()
    @State var previewedFeedbackIDs: Set<UUID> = []
    @State var presentationDelta: LivePreviewRotation = .zero

    /// Overlay mapping includes any leftover preview-vs-buffer rotation; the
    /// camera view itself only uses the operator's `liveRotation`.
    var overlayRotation: LivePreviewRotation {
        VideoRotationMath.composed(settings.liveRotation, presentationDelta)
    }

    /// Non-nil while the AprilTag detector failed to initialize - lid gating is inert.
    var tagFailureReason: String? {
        guard aprilTagStore.isEnabled else { return nil }
        return detectedTagFailure
    }

    /// The design surfaces the cleanable hint only while something is bound for residual
    /// without the pipeline being sure of it - the case rinsing would still change.
    var showsCleanableHint: Bool {
        tracks.contains { $0.beliefUncertain && $0.advisedBinID == BinGuide.residual.id }
    }

    var activeBinIDs: Set<String> {
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
                            markerDebugOverlay: markerStore.showDebugOverlay
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
                            handleDetectionResult(
                                result: result,
                                tracked: tracked,
                                zoneFrame: zoneFrame,
                                openness: openness,
                                confirmed: confirmed,
                                verdicts: verdicts
                            )
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

                    if markerStore.source == .marker, markerStore.showDebugOverlay {
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

                    if markerStore.source == .aprilTag, aprilTagStore.isEnabled, aprilTagStore.showDebugOverlay {
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

            VStack(spacing: 0) {
                topHUD

                Spacer(minLength: 0)

                bottomHUD
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
                .background(.clear)
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showSettings)
        .animation(.easeInOut(duration: 0.35), value: showStats)
    }
}

/// Smoothed pipeline FPS from callback timing; prefers the model's reported rate when present.
final class FrameRateMonitor {
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
