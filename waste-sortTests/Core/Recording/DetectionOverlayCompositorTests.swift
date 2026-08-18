import CoreGraphics
import Testing
import UIKit
@testable import waste_sort

struct DetectionOverlayCompositorTests {
    @Test func renderPreservesImageSize() {
        let image = solidImage(color: .darkGray, size: CGSize(width: 200, height: 160))
        let tracks = [
            TrackedDetection(
                id: 1,
                classKey: "organic",
                className: "organic",
                conf: 0.91,
                displayXywhn: CGRect(x: 0.1, y: 0.15, width: 0.3, height: 0.35)
            ),
            TrackedDetection(
                id: 2,
                classKey: "residual",
                className: "residual",
                conf: 0.64,
                displayXywhn: CGRect(x: 0.55, y: 0.4, width: 0.25, height: 0.3)
            ),
        ]

        let rendered = DetectionOverlayCompositor.render(
            image: image,
            tracks: tracks,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(rendered.size.width == 200)
        #expect(rendered.size.height == 160)
        #expect(rendered.cgImage != nil)
    }
}

private func solidImage(color: UIColor, size: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { ctx in
        color.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
}
