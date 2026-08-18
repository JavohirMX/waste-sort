import SwiftUI

/// Shared aspect-fill mapping used by Ultralytics YOLOView overlays.
nonisolated enum DetectionGeometry {
    /// 180° flip in normalized image space so boxes track a rotated preview
    /// without rotating badge/symbol views.
    static func flipNormalized180(_ rect: CGRect) -> CGRect {
        rotateNormalized(rect, by: .oneEighty)
    }

    static func mirrorNormalized(_ rect: CGRect) -> CGRect {
        CGRect(
            x: 1 - rect.maxX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Clockwise rotation in normalized image space (origin top-left), matching SwiftUI `rotationEffect`.
    static func rotateNormalized(_ rect: CGRect, by rotation: LivePreviewRotation) -> CGRect {
        switch rotation {
        case .zero:
            return rect
        case .ninety:
            return CGRect(
                x: 1 - rect.maxY,
                y: rect.minX,
                width: rect.height,
                height: rect.width
            )
        case .oneEighty:
            return CGRect(
                x: 1 - rect.maxX,
                y: 1 - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        case .twoSeventy:
            return CGRect(
                x: rect.minY,
                y: 1 - rect.maxX,
                width: rect.height,
                height: rect.width
            )
        }
    }

    static func coverScale(for rotation: LivePreviewRotation, viewSize: CGSize) -> CGFloat {
        guard rotation.swapsAxes, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return max(viewSize.width / viewSize.height, viewSize.height / viewSize.width)
    }

    static func mapDisplayRect(
        normalized: CGRect,
        imageSize: CGSize,
        viewSize: CGSize,
        rotation: LivePreviewRotation,
        mirror: Bool,
        useAspectFill: Bool
    ) -> CGRect {
        let placed = useAspectFill
            ? aspectFillDisplayRect(for: normalized, imageSize: imageSize, viewSize: viewSize)
            : aspectFitDisplayRect(for: normalized, imageSize: imageSize, viewSize: viewSize)
        var rect = placed
        if mirror {
            rect = CGRect(
                x: viewSize.width - rect.maxX,
                y: rect.minY,
                width: rect.width,
                height: rect.height
            )
        }
        let center = CGPoint(x: viewSize.width * 0.5, y: viewSize.height * 0.5)
        rect = rotateRect(rect, around: center, by: rotation)
        let scale = coverScale(for: rotation, viewSize: viewSize)
        if scale != 1 {
            rect = scaleRect(rect, around: center, by: scale)
        }
        return rect
    }

    static func rotateRect(_ rect: CGRect, around center: CGPoint, by rotation: LivePreviewRotation) -> CGRect {
        func transform(_ point: CGPoint) -> CGPoint {
            let rel = CGPoint(x: point.x - center.x, y: point.y - center.y)
            let rotated: CGPoint
            switch rotation {
            case .zero:
                rotated = rel
            case .ninety:
                rotated = CGPoint(x: -rel.y, y: rel.x)
            case .oneEighty:
                rotated = CGPoint(x: -rel.x, y: -rel.y)
            case .twoSeventy:
                rotated = CGPoint(x: rel.y, y: -rel.x)
            }
            return CGPoint(x: rotated.x + center.x, y: rotated.y + center.y)
        }

        let corners = [
            rect.origin,
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ].map(transform)
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? minX) - minX, height: (ys.max() ?? minY) - minY)
    }

    static func scaleRect(_ rect: CGRect, around center: CGPoint, by scale: CGFloat) -> CGRect {
        let newCenter = CGPoint(
            x: center.x + (rect.midX - center.x) * scale,
            y: center.y + (rect.midY - center.y) * scale
        )
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        return CGRect(
            x: newCenter.x - size.width * 0.5,
            y: newCenter.y - size.height * 0.5,
            width: size.width,
            height: size.height
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
    var rotation: LivePreviewRotation = .zero
    var mirror: Bool = false
    var showConfidence: Bool = false

    var body: some View {
        ZStack {
            ForEach(tracks) { track in
                let rect = mappedRect(for: track)
                if rect.width > 1, rect.height > 1 {
                    DetectionBoxView(
                        bin: BinGuide.info(for: track.classKey),
                        rect: rect,
                        confidence: track.conf,
                        showConfidence: showConfidence
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func mappedRect(for track: TrackedDetection) -> CGRect {
        DetectionGeometry.mapDisplayRect(
            normalized: track.displayXywhn,
            imageSize: imageSize,
            viewSize: viewSize,
            rotation: rotation,
            mirror: mirror,
            useAspectFill: useAspectFill
        )
    }
}

struct DetectionBoxView: View {
    let bin: BinInfo
    let rect: CGRect
    var confidence: Float = 0
    var showConfidence: Bool = false

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

    private var percentText: String {
        "\(Int((Double(confidence) * 100).rounded()))%"
    }

    @ViewBuilder
    private var categoryBadge: some View {
        if showConfidence {
            HStack(spacing: 4) {
                Image(systemName: bin.symbolName)
                    .font(.system(size: 11, weight: .bold))
                Text(percentText)
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(bin.color, in: Capsule())
        } else {
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
}
