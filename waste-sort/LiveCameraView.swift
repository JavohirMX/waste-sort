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
        ZStack(alignment: .bottom) {
            LiveYOLOCamera(settings: settings.runtime) { result, tracked in
                if let measured = fpsMonitor.tick(reportedFPS: result.fps) {
                    fps = measured
                }
                imageSize = result.orig_shape
                tracks = tracked

                var nextCounts: [String: Int] = [:]
                for track in tracked {
                    nextCounts[track.classKey, default: 0] += 1
                }
                if nextCounts != counts {
                    counts = nextCounts
                }
            }
            .ignoresSafeArea()

            GeometryReader { geo in
                DetectionOverlay(
                    tracks: tracks,
                    imageSize: imageSize,
                    viewSize: geo.size
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Text("\(fps) FPS")
                        .font(.system(.caption, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .accessibilityLabel("\(fps) frames per second")
                        .accessibilityAction(named: "Open settings") {
                            showSettings = true
                        }
                        .onLongPressGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showSettings = true
                        }
                }
                .padding(.top, 12)

                Spacer()

                BinLegend(counts: counts)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Draws smoothed track boxes using the same aspect-fill mapping as Ultralytics `YOLOView`.
private struct DetectionOverlay: View {
    let tracks: [TrackedDetection]
    let imageSize: CGSize
    let viewSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else {
                return
            }
            for track in tracks {
                let rect = aspectFillDisplayRect(
                    for: track.displayXywhn,
                    imageSize: imageSize,
                    viewSize: size
                )
                guard rect.width > 1, rect.height > 1 else { continue }

                let bin = BinGuide.info(for: track.classKey)
                let path = Path(roundedRect: rect, cornerRadius: 4)

                context.fill(path, with: .color(bin.color.opacity(0.22)))
                context.stroke(path, with: .color(bin.color), lineWidth: 3)

                let label = "\(bin.title) \(Int(track.conf * 100))%"
                let text = Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                let resolved = context.resolve(text)
                let textSize = resolved.measure(in: CGSize(width: 220, height: 40))
                let padX: CGFloat = 4
                let padY: CGFloat = 2
                let labelSize = CGSize(
                    width: textSize.width + padX * 2,
                    height: textSize.height + padY * 2
                )
                let aboveY = rect.minY - labelSize.height - 4
                let preferredY = aboveY >= 0 ? aboveY : rect.minY + 4
                let labelRect = CGRect(
                    x: min(max(0, rect.minX), max(0, size.width - labelSize.width)),
                    y: min(max(0, preferredY), max(0, size.height - labelSize.height)),
                    width: labelSize.width,
                    height: labelSize.height
                )
                context.fill(
                    Path(roundedRect: labelRect, cornerRadius: 4),
                    with: .color(bin.color.opacity(0.92))
                )
                context.draw(
                    resolved,
                    at: CGPoint(x: labelRect.minX + padX, y: labelRect.minY + padY),
                    anchor: .topLeading
                )
            }
        }
    }
}

/// Matches Ultralytics YOLOView's aspect-fill overlay mapping for normalized boxes.
private func aspectFillDisplayRect(
    for normalizedRect: CGRect,
    imageSize: CGSize,
    viewSize: CGSize
) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
        return .zero
    }
    let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    let scaledImageSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let offset = CGPoint(
        x: (scaledImageSize.width - viewSize.width) / 2,
        y: (scaledImageSize.height - viewSize.height) / 2
    )
    return CGRect(
        x: normalizedRect.minX * imageSize.width * scale - offset.x,
        y: normalizedRect.minY * imageSize.height * scale - offset.y,
        width: normalizedRect.width * imageSize.width * scale,
        height: normalizedRect.height * imageSize.height * scale
    )
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

private struct BinLegend: View {
    let counts: [String: Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BinGuide.all) { bin in
                let count = counts[bin.id] ?? 0
                VStack(spacing: 4) {
                    Text("\(count)")
                        .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                    Text(bin.title)
                        .font(.system(.caption2, design: .rounded).weight(.medium))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(bin.color.opacity(count > 0 ? 0.92 : 0.55))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(legendLabel)
    }

    private var legendLabel: String {
        BinGuide.all
            .map { "\($0.title) \(counts[$0.id] ?? 0)" }
            .joined(separator: ", ")
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
