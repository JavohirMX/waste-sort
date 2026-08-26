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

    // MARK: - Point mapping (drop zone corners)

    static func mirrorNormalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.x, y: point.y)
    }

    /// Point form of `rotateNormalized(_:by:)` — the rect version is its bounding box.
    static func rotateNormalized(_ point: CGPoint, by rotation: LivePreviewRotation) -> CGPoint {
        switch rotation {
        case .zero:
            return point
        case .ninety:
            return CGPoint(x: 1 - point.y, y: point.x)
        case .oneEighty:
            return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .twoSeventy:
            return CGPoint(x: point.y, y: 1 - point.x)
        }
    }

    /// Point form of `mapDisplayRect`, for geometry that must survive rotation as a
    /// shape rather than a bounding box.
    static func mapDisplayPoint(
        normalized: CGPoint,
        imageSize: CGSize,
        viewSize: CGSize,
        rotation: LivePreviewRotation,
        mirror: Bool,
        useAspectFill: Bool
    ) -> CGPoint {
        guard let placement = Placement(
            imageSize: imageSize,
            viewSize: viewSize,
            useAspectFill: useAspectFill
        ) else { return .zero }

        var point = CGPoint(
            x: normalized.x * imageSize.width * placement.scale - placement.offset.x,
            y: normalized.y * imageSize.height * placement.scale - placement.offset.y
        )
        if mirror {
            point.x = viewSize.width - point.x
        }
        let center = CGPoint(x: viewSize.width * 0.5, y: viewSize.height * 0.5)
        point = rotatePoint(point, around: center, by: rotation)
        let scale = coverScale(for: rotation, viewSize: viewSize)
        if scale != 1 {
            point = scalePoint(point, around: center, by: scale)
        }
        return point
    }

    /// Exact inverse of `mapDisplayPoint` — turns a drag location back into image space.
    static func mapNormalizedPoint(
        viewPoint: CGPoint,
        imageSize: CGSize,
        viewSize: CGSize,
        rotation: LivePreviewRotation,
        mirror: Bool,
        useAspectFill: Bool
    ) -> CGPoint {
        guard let placement = Placement(
            imageSize: imageSize,
            viewSize: viewSize,
            useAspectFill: useAspectFill
        ) else { return .zero }

        var point = viewPoint
        let center = CGPoint(x: viewSize.width * 0.5, y: viewSize.height * 0.5)
        let scale = coverScale(for: rotation, viewSize: viewSize)
        if scale != 1 {
            point = scalePoint(point, around: center, by: 1 / scale)
        }
        point = rotatePoint(point, around: center, by: inverse(rotation))
        if mirror {
            point.x = viewSize.width - point.x
        }
        return CGPoint(
            x: (point.x + placement.offset.x) / (imageSize.width * placement.scale),
            y: (point.y + placement.offset.y) / (imageSize.height * placement.scale)
        )
    }

    static func rotatePoint(
        _ point: CGPoint,
        around center: CGPoint,
        by rotation: LivePreviewRotation
    ) -> CGPoint {
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

    static func scalePoint(_ point: CGPoint, around center: CGPoint, by scale: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + (point.x - center.x) * scale,
            y: center.y + (point.y - center.y) * scale
        )
    }

    static func inverse(_ rotation: LivePreviewRotation) -> LivePreviewRotation {
        switch rotation {
        case .zero: return .zero
        case .ninety: return .twoSeventy
        case .oneEighty: return .oneEighty
        case .twoSeventy: return .ninety
        }
    }

    /// Shared placement maths for both fill and fit: `view = n * image * scale - offset`.
    private struct Placement {
        let scale: CGFloat
        let offset: CGPoint

        init?(imageSize: CGSize, viewSize: CGSize, useAspectFill: Bool) {
            guard imageSize.width > 0, imageSize.height > 0,
                  viewSize.width > 0, viewSize.height > 0
            else { return nil }
            let ratios = (viewSize.width / imageSize.width, viewSize.height / imageSize.height)
            scale = useAspectFill ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)
            offset = CGPoint(
                x: (imageSize.width * scale - viewSize.width) / 2,
                y: (imageSize.height * scale - viewSize.height) / 2
            )
        }
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
