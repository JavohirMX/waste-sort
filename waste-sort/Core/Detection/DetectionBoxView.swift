import SwiftUI

/// Shared aspect-fill mapping used by Ultralytics YOLOView overlays.
enum DetectionGeometry {
    /// 180° flip in normalized image space so boxes track a rotated preview
    /// without rotating badge/symbol views.
    static func flipNormalized180(_ rect: CGRect) -> CGRect {
        CGRect(
            x: 1 - rect.maxX,
            y: 1 - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func aspectFillDisplayRect(
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

    /// Fit (not fill) mapping for photo results that use `.scaledToFit`.
    static func aspectFitDisplayRect(
        for normalizedRect: CGRect,
        imageSize: CGSize,
        viewSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaledImageSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let offset = CGPoint(
            x: (viewSize.width - scaledImageSize.width) / 2,
            y: (viewSize.height - scaledImageSize.height) / 2
        )
        return CGRect(
            x: normalizedRect.minX * imageSize.width * scale + offset.x,
            y: normalizedRect.minY * imageSize.height * scale + offset.y,
            width: normalizedRect.width * imageSize.width * scale,
            height: normalizedRect.height * imageSize.height * scale
        )
    }
}

/// Detection frames with subtle category fill, stroke, and corner badge.
struct DetectionBoxOverlay: View {
    let tracks: [TrackedDetection]
    let imageSize: CGSize
    let viewSize: CGSize
    var useAspectFill: Bool = true
    /// When the live preview is rotated 180°, remap box coords without rotating symbols.
    var flipNormalized180: Bool = false

    var body: some View {
        ZStack {
            ForEach(tracks) { track in
                let rect = mappedRect(for: track)
                if rect.width > 1, rect.height > 1 {
                    DetectionBoxView(
                        bin: BinGuide.info(for: track.classKey),
                        rect: rect
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func mappedRect(for track: TrackedDetection) -> CGRect {
        let normalized = flipNormalized180
            ? DetectionGeometry.flipNormalized180(track.displayXywhn)
            : track.displayXywhn
        if useAspectFill {
            return DetectionGeometry.aspectFillDisplayRect(
                for: normalized,
                imageSize: imageSize,
                viewSize: viewSize
            )
        }
        return DetectionGeometry.aspectFitDisplayRect(
            for: normalized,
            imageSize: imageSize,
            viewSize: viewSize
        )
    }
}

struct DetectionBoxView: View {
    let bin: BinInfo
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.boxCornerRadius, style: .continuous)
            .fill(bin.color.opacity(Theme.boxFillOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.boxCornerRadius, style: .continuous)
                    .strokeBorder(bin.color, lineWidth: Theme.boxStrokeWidth)
            }
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .topTrailing) {
                categoryBadge
                    .offset(x: Theme.badgeSize * 0.35, y: -Theme.badgeSize * 0.35)
            }
            .position(x: rect.midX, y: rect.midY)
            .accessibilityHidden(true)
    }

    private var categoryBadge: some View {
        ZStack {
            Circle()
                .fill(bin.color)
                .frame(width: Theme.badgeSize, height: Theme.badgeSize)
            Image(systemName: bin.symbolName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
