import Foundation
import Testing
@testable import waste_sort

/// Pins the directional behavior of the color/texture prior on synthetic crops:
/// matte green-brown noise reads organic, smooth glossy neutrals read recyclable,
/// bright crinkled film reads residual. Absolute values are irrelevant; ordering is
/// the contract.
struct AppearanceAnalyzerTests {
    private let side = 48

    private func share(_ key: String, _ shares: [String: Double]) -> Double {
        shares[key] ?? 0
    }

    /// Builds a BGRA buffer from a per-pixel HSV closure.
    private func buffer(hsv: (Int, Int) -> (h: Double, s: Double, v: Double)) -> AppearanceSample {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let (h, s, v) = hsv(x, y)
                let (r, g, b) = Self.hsvToRGB(h: h, s: s, v: v)
                let offset = (y * side + x) * 4
                bytes[offset] = UInt8((b * 255).rounded())
                bytes[offset + 1] = UInt8((g * 255).rounded())
                bytes[offset + 2] = UInt8((r * 255).rounded())
                bytes[offset + 3] = 255
            }
        }
        return AppearanceSample(bytes: bytes, width: side, height: side, bytesPerRow: side * 4)
    }

    private static func hsvToRGB(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let c = v * s
        let hp = h.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = v - c
        return (r1 + m, g1 + m, b1 + m)
    }

    @Test("matte green-brown texture reads organic")
    func organicPriorDominates() {
        // Olive-green base with strong luma checkerboarding: food/plant matter.
        let sample = buffer { x, y in
            let checker = ((x + y) % 2 == 0) ? 0.25 : -0.25
            return (h: 95, s: 0.45, v: min(max(0.55 + checker, 0), 1))
        }

        let shares = AppearanceAnalyzer.prior(for: sample).shares

        #expect(share(BinGuide.organic.id, shares) > share(BinGuide.cleanInorganic.id, shares))
        #expect(share(BinGuide.organic.id, shares) > share(BinGuide.residual.id, shares))
    }

    @Test("smooth glossy neutral reads recyclable")
    func recyclablePriorDominates() {
        // Uniform light-gray body with a specular hotspot block.
        let sample = buffer { x, y in
            let hotspot = x > side / 2 && y < side / 2
            return (h: 210, s: hotspot ? 0.02 : 0.05, v: hotspot ? 1.0 : 0.85)
        }

        let shares = AppearanceAnalyzer.prior(for: sample).shares

        #expect(share(BinGuide.cleanInorganic.id, shares) > share(BinGuide.organic.id, shares))
    }

    @Test("bright fine-striped film reads residual")
    func residualPriorDominates() {
        // Near-white crinkled film: high value, low saturation, dense luma stripes.
        let sample = buffer { x, y in
            let stripe = (x % 3 == 0) ? -0.35 : 0.0
            return (h: 40, s: 0.06, v: min(0.92 + stripe, 1))
        }

        let shares = AppearanceAnalyzer.prior(for: sample).shares

        #expect(share(BinGuide.residual.id, shares) > share(BinGuide.organic.id, shares))
    }

    @Test("shares always sum to approximately one")
    func sharesNormalize() {
        let flat = buffer { _, _ in (h: 0, s: 0, v: 0.5) }
        let shares = AppearanceAnalyzer.prior(for: flat).shares
        let total = shares.values.reduce(0, +)
        #expect(abs(total - 1.0) < 1e-9)
        #expect(shares.count == 3)
    }

    @Test("features separate textured from smooth inputs")
    func textureEnergySeparates() {
        let smooth = buffer { _, _ in (h: 90, s: 0.4, v: 0.6) }
        let noisy = buffer { x, y in
            (h: 90, s: 0.4, v: (x + y) % 2 == 0 ? 0.85 : 0.35)
        }

        let smoothFeatures = AppearanceAnalyzer.features(for: smooth)
        let noisyFeatures = AppearanceAnalyzer.features(for: noisy)

        #expect(noisyFeatures.textureEnergy > smoothFeatures.textureEnergy * 3)
        #expect(smoothFeatures.textureEnergy < 0.05)
    }
}
