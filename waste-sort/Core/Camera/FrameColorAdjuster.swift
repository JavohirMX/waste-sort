import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import UIKit

/// Software color knobs applied to frames before YOLO, and shown on Live when not identity.
struct FrameColorControls: Equatable {
    var brightness: Double
    var contrast: Double
    var saturation: Double

    static let identity = FrameColorControls(brightness: 0, contrast: 1, saturation: 1)

    var isIdentity: Bool {
        abs(brightness) < 0.0001 && abs(contrast - 1) < 0.0001 && abs(saturation - 1) < 0.0001
    }

    var clamped: FrameColorControls {
        FrameColorControls(
            brightness: FrameColorAdjuster.clampedBrightness(brightness),
            contrast: FrameColorAdjuster.clampedContrast(contrast),
            saturation: FrameColorAdjuster.clampedSaturation(saturation)
        )
    }
}

/// Applies `CIColorControls` through a shared `CIContext`. Identity (0 / 1 / 1) is a no-op.
enum FrameColorAdjuster {
    static let brightnessRange: ClosedRange<Double> = -0.5...0.5
    static let contrastRange: ClosedRange<Double> = 0.5...1.5
    static let saturationRange: ClosedRange<Double> = 0...2

    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func clampedBrightness(_ value: Double) -> Double {
        clamped(value, in: brightnessRange)
    }

    static func clampedContrast(_ value: Double) -> Double {
        clamped(value, in: contrastRange)
    }

    static func clampedSaturation(_ value: Double) -> Double {
        clamped(value, in: saturationRange)
    }

    static func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }

    static func apply(_ controls: FrameColorControls, to image: CIImage) -> CIImage {
        let clamped = controls.clamped
        guard !clamped.isIdentity else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = Float(clamped.brightness)
        filter.contrast = Float(clamped.contrast)
        filter.saturation = Float(clamped.saturation)
        return filter.outputImage ?? image
    }

    /// Renders color controls onto `pixelBuffer` in place. Returns `false` when identity (no write).
    @discardableResult
    static func processInPlace(_ pixelBuffer: CVPixelBuffer, controls: FrameColorControls) -> Bool {
        let clamped = controls.clamped
        guard !clamped.isIdentity else { return false }
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let output = apply(clamped, to: input)
        context.render(output, to: pixelBuffer)
        return true
    }

    static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return context.createCGImage(image, from: image.extent)
    }

    static func ciImage(from uiImage: UIImage) -> CIImage {
        if let cgImage = uiImage.cgImage {
            let orientation = CGImagePropertyOrientation(uiImage.imageOrientation)
            return CIImage(cgImage: cgImage).oriented(orientation)
        }
        return CIImage(image: uiImage) ?? CIImage.empty()
    }

    static func uiImage(from ciImage: CIImage) -> UIImage? {
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
