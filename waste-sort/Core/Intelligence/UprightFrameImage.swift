import CoreGraphics
import UIKit

/// `CGImage` carries no orientation, so a crop in raw pixel space lands in the wrong place
/// whenever the frame it came from was tagged sideways. This pins the pixels upright first.
nonisolated enum UprightFrameImage {
    static func cgImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}
