import CoreGraphics
import Foundation
import UIKit

/// A tiny downsampled crop of one detection, ready for feature extraction.
nonisolated struct AppearanceSample: Equatable, Sendable {
    /// Packed BGRA bytes, `bytesPerRow`-strided, `side × side` pixels.
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int

    var pixelCount: Int { width * height }
}

/// Soft color/texture evidence over the three Bali streams, fused into an object's
/// belief alongside the model's own verdicts.
///
/// This is a *prior*, not a verdict: it exists because YOLO confidences flip on
/// borderline items while the pixels sitting inside the box do not — a banana peel is
/// green-brown and matte under any lighting this kiosk will see. Weights are deliberately
/// modest (see `WasteSortConfig.defaultAppearanceWeight`) so appearance nudges coin
/// flips without ever outvoting consistent model evidence.
nonisolated struct AppearancePrior: Equatable, Sendable {
    /// Soft shares keyed by bin id (organic / residual / clean_inorganic), summing to ≈1.
    let shares: [String: Double]
}

/// Extracts hand-tuned color/texture features from a small crop and maps them to
/// stream shares. Pure math so synthetic buffers drive the tests.
nonisolated enum AppearanceAnalyzer {
    /// Feature vector extracted once per sample; exposed for tests and tuning.
    nonisolated struct Features: Equatable, Sendable {
        /// Fraction of clearly green/yellow-green/brown pixels — plant matter and food.
        let greenFraction: Double
        /// Fraction of warm mid-saturation browns (cardboard-adjacent organics).
        let brownFraction: Double
        /// Fraction of bright near-white pixels (paper, film, gloss).
        let whiteFraction: Double
        /// Fraction of desaturated mid-gray pixels (mixed dirty waste).
        let grayFraction: Double
        /// Fraction of harsh specular highlights (glossy rigid plastic, metal, glass).
        let specularRatio: Double
        /// Mean absolute luma difference between adjacent pixels, normalized. Matte
        /// food waste runs high; smooth rigid packaging runs low.
        let textureEnergy: Double
    }

    /// How sharply raw scores are sharpened before normalization. Higher = winner
    /// takes more of the mass.
    private static let sharpness = 3.0

    static func prior(for sample: AppearanceSample) -> AppearancePrior {
        let f = features(for: sample)
        let organicScore = 1.10 * f.greenFraction + 0.50 * f.brownFraction + 0.55 * f.textureEnergy
        let recyclableScore = 0.90 * f.specularRatio
            + 0.75 * f.whiteFraction * (1.0 - min(f.textureEnergy * 2.0, 1.0))
            + 0.65 * saturatedShare(sample)
        let residualScore = 0.70 * f.grayFraction
            + 0.85 * min(f.whiteFraction * f.textureEnergy * 2.2, 1.0)
        return AppearancePrior(shares: normalize(
            [
                BinGuide.organic.id: organicScore,
                BinGuide.cleanInorganic.id: recyclableScore,
                BinGuide.residual.id: residualScore
            ]
        ))
    }

    static func features(for sample: AppearanceSample) -> Features {
        var greenCount = 0
        var brownCount = 0
        var whiteCount = 0
        var grayCount = 0
        var specularCount = 0
        var saturatedCount = 0
        var textureSum = 0.0
        var textureSamples = 0.0
        var previousLumaRow: [Double]?

        for y in 0..<sample.height {
            var currentLumaRow = [Double](repeating: 0, count: sample.width)
            for x in 0..<sample.width {
                let offset = y * sample.bytesPerRow + x * 4
                let b = Double(sample.bytes[offset]) / 255
                let g = Double(sample.bytes[offset + 1]) / 255
                let r = Double(sample.bytes[offset + 2]) / 255
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                currentLumaRow[x] = luma

                if x > 0 {
                    textureSum += abs(luma - currentLumaRow[x - 1])
                    textureSamples += 1
                }
                if let previous = previousLumaRow {
                    textureSum += abs(luma - previous[x])
                    textureSamples += 1
                }

                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let delta = maxC - minC
                guard maxC > 0 else {
                    grayCount += 1
                    continue
                }
                let saturation = maxC > 0 ? delta / maxC : 0
                let value = maxC
                let hue = hueDegrees(r: r, g: g, b: b, maxC: maxC, delta: delta)

                if saturation > 0.18, hue >= 15, hue <= 150 {
                    greenCount += 1
                }
                if saturation > 0.20, hue > 15, hue < 45, value > 0.25, value < 0.85 {
                    brownCount += 1
                }
                if value > 0.78, saturation < 0.12 {
                    whiteCount += 1
                }
                if value > 0.92, saturation < 0.16 {
                    specularCount += 1
                }
                if saturation > 0.45 {
                    saturatedCount += 1
                }
                if value > 0.35, value < 0.80, saturation > 0.08, saturation < 0.30 {
                    grayCount += 1
                }
            }
            previousLumaRow = currentLumaRow
        }

        let n = Double(max(sample.pixelCount, 1))
        return Features(
            greenFraction: Double(greenCount) / n,
            brownFraction: Double(brownCount) / n,
            whiteFraction: Double(whiteCount) / n,
            grayFraction: Double(grayCount) / n,
            specularRatio: Double(specularCount) / n,
            textureEnergy: textureSamples > 0 ? min(textureSum / textureSamples / 0.35, 1) : 0
        )
    }

    private static func saturatedShare(_ sample: AppearanceSample) -> Double {
        var saturated = 0
        for y in 0..<sample.height {
            for x in 0..<sample.width {
                let offset = y * sample.bytesPerRow + x * 4
                let r = Double(sample.bytes[offset + 2]) / 255
                let g = Double(sample.bytes[offset + 1]) / 255
                let b = Double(sample.bytes[offset]) / 255
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                if maxC > 0, (maxC - minC) / maxC > 0.55 {
                    saturated += 1
                }
            }
        }
        return Double(saturated) / Double(max(sample.pixelCount, 1))
    }

    private static func hueDegrees(r: Double, g: Double, b: Double, maxC: Double, delta: Double) -> Double {
        guard delta > 0 else { return 0 }
        if maxC == r {
            let h = 60 * ((g - b) / delta)
            return h.truncatingRemainder(dividingBy: 360).rounded(.down) + (h < 0 ? 360 : 0)
        }
        if maxC == g {
            return 60 * ((b - r) / delta) + 120
        }
        return 60 * ((r - g) / delta) + 240
    }

    private static func normalize(_ scores: [String: Double]) -> [String: Double] {
        let sharpened = scores.mapValues { pow(max($0, 0), sharpness) }
        let total = sharpened.values.reduce(0, +)
        guard total > 0 else {
            return scores.mapValues { _ in 1.0 / Double(max(scores.count, 1)) }
        }
        return sharpened.mapValues { $0 / total }
    }
}

/// Draws a normalized box region of a frame into one reusable tiny buffer.
///
/// Owned by the inference queue like the tracker — no locking. The context persists
/// across frames so sampling costs one draw plus two array passes, never an allocation.
final class BoxAppearanceSampler {
    private let side = 48
    private lazy var context: CGContext? = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )

    /// Returns the downsampled crop for `rectNorm`, or nil when the image cannot be drawn.
    func sample(image: UIImage, rectNorm: CGRect) -> AppearanceSample? {
        guard let cgImage = image.cgImageOrRendered,
              let context,
              rectNorm.width > 0, rectNorm.height > 0
        else { return nil }
        let fullWidth = CGFloat(cgImage.width)
        let fullHeight = CGFloat(cgImage.height)
        let clamped = rectNorm.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull else { return nil }
        let crop = CGRect(
            x: clamped.minX * fullWidth,
            y: clamped.minY * fullHeight,
            width: max(clamped.width * fullWidth, 1),
            height: max(clamped.height * fullHeight, 1)
        ).integral

        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let cropped = cgImage.cropping(to: crop) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))

        guard let data = context.data else { return nil }
        let byteCount = side * side * 4
        let buffer = data.bindMemory(to: UInt8.self, capacity: byteCount)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress?.update(from: buffer, count: byteCount)
        }
        return AppearanceSample(
            bytes: bytes,
            width: side,
            height: side,
            bytesPerRow: side * 4
        )
    }
}

/// CIImage-backed images (what the predictor hands over during recording) have no
/// cgImage; render through a minimal context. Shared by appearance sampling and zoom
/// re-check cropping.
nonisolated extension UIImage {
    var cgImageOrRendered: CGImage? {
        if let cgImage { return cgImage }
        guard let ciImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
