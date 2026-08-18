import CoreGraphics
import UIKit

/// Burns tracked boxes, class, confidence, and a clock onto a camera frame.
nonisolated enum DetectionOverlayCompositor {
    static func render(
        image: UIImage,
        tracks: [TrackedDetection],
        zones: [DropZone] = [],
        timestamp: Date,
        rotation: LivePreviewRotation = .oneEighty,
        mirror: Bool = false
    ) -> UIImage {
        let source = image.normalizedCGImage() ?? image
        let transformed = source.transformed(rotation: rotation, mirror: mirror)
        let size = transformed.size
        guard size.width > 1, size.height > 1 else { return transformed }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            transformed.draw(in: CGRect(origin: .zero, size: size))

            let stroke = max(3, size.width * 0.0035)
            let fontSize = max(16, size.width * 0.02)
            let corner = max(6, size.width * 0.008)

            for zone in zones {
                drawZone(
                    zone: zone,
                    canvasSize: size,
                    rotation: rotation,
                    mirror: mirror,
                    stroke: stroke,
                    fontSize: fontSize
                )
            }

            for track in tracks {
                var normalized = track.displayXywhn
                if mirror {
                    normalized = DetectionGeometry.mirrorNormalized(normalized)
                }
                normalized = DetectionGeometry.rotateNormalized(normalized, by: rotation)
                let rect = CGRect(
                    x: normalized.minX * size.width,
                    y: normalized.minY * size.height,
                    width: normalized.width * size.width,
                    height: normalized.height * size.height
                )
                guard rect.width > 2, rect.height > 2 else { continue }
                drawBox(
                    rect: rect,
                    classKey: track.classKey,
                    confidence: track.conf,
                    canvasWidth: size.width,
                    stroke: stroke,
                    fontSize: fontSize,
                    corner: corner
                )
            }

            drawTimestamp(timestamp, canvasSize: size, fontSize: fontSize)
        }
    }

    private static func drawZone(
        zone: DropZone,
        canvasSize: CGSize,
        rotation: LivePreviewRotation,
        mirror: Bool,
        stroke: CGFloat,
        fontSize: CGFloat
    ) {
        let points = zone.corners.map { corner -> CGPoint in
            var normalized = corner
            if mirror {
                normalized = DetectionGeometry.mirrorNormalized(normalized)
            }
            normalized = DetectionGeometry.rotateNormalized(normalized, by: rotation)
            return CGPoint(x: normalized.x * canvasSize.width, y: normalized.y * canvasSize.height)
        }
        guard points.count >= 3 else { return }

        let color = OverlayBinStyle.uiColor(for: zone.binID)
        let path = UIBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.close()

        color.withAlphaComponent(0.12).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = stroke
        path.lineJoinStyle = .round
        path.setLineDash([stroke * 4, stroke * 2.5], count: 2, phase: 0)
        path.stroke()

        let center = points.reduce(CGPoint.zero) {
            CGPoint(
                x: $0.x + $1.x / CGFloat(points.count),
                y: $0.y + $1.y / CGFloat(points.count)
            )
        }
        let label = zone.name.uppercased()
        let font = UIFont.systemFont(ofSize: fontSize * 0.85, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: fontSize * 0.4, height: fontSize * 0.2)
        let badgeRect = CGRect(
            x: center.x - (textSize.width + padding.width * 2) / 2,
            y: center.y - (textSize.height + padding.height * 2) / 2,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeRect.height / 2)
        color.withAlphaComponent(0.9).setFill()
        badgePath.fill()
        (label as NSString).draw(
            in: CGRect(
                x: badgeRect.minX + padding.width,
                y: badgeRect.minY + padding.height,
                width: textSize.width,
                height: textSize.height
            ),
            withAttributes: attributes
        )
    }

    private static func drawBox(
        rect: CGRect,
        classKey: String,
        confidence: Float,
        canvasWidth: CGFloat,
        stroke: CGFloat,
        fontSize: CGFloat,
        corner: CGFloat
    ) {
        let color = OverlayBinStyle.uiColor(for: classKey)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: corner)
        color.withAlphaComponent(0.22).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = stroke
        path.stroke()

        let percent = Int((Double(confidence) * 100).rounded())
        let label = "\(OverlayBinStyle.displayName(for: classKey))  \(percent)%"
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: fontSize * 0.45, height: fontSize * 0.22)
        let badgeSize = CGSize(
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        var badgeOrigin = CGPoint(x: rect.minX, y: rect.minY - badgeSize.height - 4)
        if badgeOrigin.y < 0 {
            badgeOrigin.y = rect.minY + 4
        }
        badgeOrigin.x = min(max(0, badgeOrigin.x), max(0, canvasWidth - badgeSize.width))
        let badgeRect = CGRect(origin: badgeOrigin, size: badgeSize)
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeSize.height / 2)
        color.setFill()
        badgePath.fill()
        (label as NSString).draw(
            in: CGRect(
                x: badgeRect.minX + padding.width,
                y: badgeRect.minY + padding.height,
                width: textSize.width,
                height: textSize.height
            ),
            withAttributes: attributes
        )
    }

    private static func drawTimestamp(
        _ date: Date,
        canvasSize: CGSize,
        fontSize: CGFloat
    ) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        let text = formatter.string(from: date)
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: fontSize * 0.55, height: fontSize * 0.28)
        let badgeSize = CGSize(
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        let badgeRect = CGRect(
            x: (canvasSize.width - badgeSize.width) / 2,
            y: max(12, canvasSize.height * 0.02),
            width: badgeSize.width,
            height: badgeSize.height
        )
        let path = UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeSize.height / 2)
        UIColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
        (text as NSString).draw(
            in: CGRect(
                x: badgeRect.minX + padding.width,
                y: badgeRect.minY + padding.height,
                width: textSize.width,
                height: textSize.height
            ),
            withAttributes: attributes
        )
    }
}

nonisolated enum OverlayBinStyle {
    static func displayName(for classKey: String) -> String {
        switch normalized(classKey) {
        case "organic": return "ORGANIC"
        case "residual": return "RESIDUAL"
        case "clean_inorganic", "cleaninorganic", "inorganic": return "INORGANIC"
        default: return "UNKNOWN"
        }
    }

    static func uiColor(for classKey: String) -> UIColor {
        switch normalized(classKey) {
        case "organic":
            return UIColor(red: 34 / 255, green: 197 / 255, blue: 94 / 255, alpha: 1)
        case "residual":
            return UIColor(red: 39 / 255, green: 39 / 255, blue: 42 / 255, alpha: 1)
        case "clean_inorganic", "cleaninorganic", "inorganic":
            return UIColor(red: 234 / 255, green: 179 / 255, blue: 8 / 255, alpha: 1)
        default:
            return UIColor(red: 113 / 255, green: 113 / 255, blue: 122 / 255, alpha: 1)
        }
    }

    private static func normalized(_ classKey: String) -> String {
        classKey
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}

nonisolated private extension UIImage {
    func normalizedCGImage() -> UIImage? {
        guard cgImage != nil else { return nil }
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func transformed(rotation: LivePreviewRotation, mirror: Bool) -> UIImage {
        var image = self
        if mirror {
            image = image.mirroredHorizontally()
        }
        return image.rotated(by: rotation)
    }

    func mirroredHorizontally() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: size.width, y: 0)
            ctx.cgContext.scaleBy(x: -1, y: 1)
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func rotated(by rotation: LivePreviewRotation) -> UIImage {
        switch rotation {
        case .zero:
            return self
        case .oneEighty:
            return rotated180()
        case .ninety, .twoSeventy:
            let newSize = CGSize(width: size.height, height: size.width)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            return renderer.image { ctx in
                if rotation == .ninety {
                    ctx.cgContext.translateBy(x: newSize.width, y: 0)
                    ctx.cgContext.rotate(by: .pi / 2)
                } else {
                    ctx.cgContext.translateBy(x: 0, y: newSize.height)
                    ctx.cgContext.rotate(by: -.pi / 2)
                }
                draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }

    func rotated180() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: size.width, y: size.height)
            ctx.cgContext.rotate(by: .pi)
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
