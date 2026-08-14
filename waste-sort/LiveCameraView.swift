import SwiftUI
import UIKit
import UltralyticsYOLO

struct LiveCameraView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var counts: [String: Int] = [:]
    @State private var fps = 0
    @State private var tracks: [TrackedDetection] = []
    @State private var imageSize: CGSize = .zero
    @State private var fpsMonitor = FrameRateMonitor()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LiveYOLOCamera(settings: settings.runtime) { result, tracked in
                if let measured = fpsMonitor.tick(reportedFPS: result.fps) {
                    fps = measured
                }
                imageSize = result.orig_shape
                tracks = tracked

                var nextCounts: [String: Int] = [:]
                for track in tracked {
                    let binID = BinGuide.info(for: track.classKey).id
                    guard binID != BinGuide.unknown.id else { continue }
                    nextCounts[binID, default: 0] += 1
                }
                if nextCounts != counts {
                    counts = nextCounts
                }
            }
            .ignoresSafeArea()

            GeometryReader { geo in
                DetectionBoxOverlay(
                    tracks: tracks,
                    imageSize: imageSize,
                    viewSize: geo.size,
                    useAspectFill: true
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Spacer(minLength: 0)
                    CategoryBar(counts: counts)
                        .frame(maxWidth: Theme.barMaxWidth)
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .topTrailing) {
                    fpsBadge
                }
                .padding(.horizontal, Theme.hudInset)
                .padding(.top, 12)

                Spacer(minLength: 0)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
            .padding(.top, 4)
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

/// YOLOCamera wrapper that loads `best` as segment, sets thresholds, and hides developer chrome.
private struct LiveYOLOCamera: UIViewRepresentable {
    var settings: RuntimeSettings
    var onDetection: ((YOLOResult, [TrackedDetection]) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(settings: settings, onDetection: onDetection)
    }

    func makeUIView(context: Context) -> YOLOView {
        let view = YOLOView(
            frame: .zero,
            modelPathOrName: WasteSortConfig.modelName,
            task: .segment
        )
        applyThresholds(view, settings: settings)
        applyTracking(context.coordinator, settings: settings)
        view.showOverlays = false
        hideDeveloperChrome(view)
        let coordinator = context.coordinator
        coordinator.yoloView = view
        view.onDetection = { result in
            coordinator.handle(result)
        }
        return view
    }

    func updateUIView(_ uiView: YOLOView, context: Context) {
        context.coordinator.onDetection = onDetection
        context.coordinator.yoloView = uiView
        applyThresholds(uiView, settings: settings)
        applyTracking(context.coordinator, settings: settings)
        let coordinator = context.coordinator
        uiView.onDetection = { result in
            coordinator.handle(result)
        }
        uiView.showOverlays = false
        hideDeveloperChrome(uiView)
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
        coordinator.tracker.emaAlpha = CGFloat(settings.emaAlpha)
        coordinator.tracker.boxInflate = CGFloat(settings.boxInflate)
        coordinator.tracker.maxSpeed = CGFloat(settings.maxSpeed)
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
        var onDetection: ((YOLOResult, [TrackedDetection]) -> Void)?
        var settings: RuntimeSettings
        weak var yoloView: YOLOView?
        let tracker = DetectionTracker()

        init(settings: RuntimeSettings, onDetection: ((YOLOResult, [TrackedDetection]) -> Void)?) {
            self.settings = settings
            self.onDetection = onDetection
        }

        func handle(_ result: YOLOResult) {
            if let view = yoloView {
                view.setConfidenceThreshold(settings.confidence)
                view.setIouThreshold(settings.iou)
                view.setNumItemsThreshold(settings.maxItems)
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
            let tracked = tracker.update(raw)
            DispatchQueue.main.async {
                self.onDetection?(result, tracked)
            }
        }
    }
}
