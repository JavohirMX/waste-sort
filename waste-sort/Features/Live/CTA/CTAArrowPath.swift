import CoreGraphics
import Foundation

nonisolated struct CTAChevronSample: Equatable {
    let point: CGPoint
    let angle: CGFloat
    let size: CGFloat
    let opacity: Double
}

/// Quadratic path from a detection box toward its matching bin tab.
nonisolated enum CTAArrowPath {
    static let spacing: CGFloat = 44
    static let minCount = 3
    static let maxCount = 16
    private static let lengthSamples = 24

    static func quadraticPoint(
        t: CGFloat,
        start: CGPoint,
        control: CGPoint,
        end: CGPoint
    ) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * start.x + 2 * mt * t * control.x + t * t * end.x,
            y: mt * mt * start.y + 2 * mt * t * control.y + t * t * end.y
        )
    }

    static func quadraticTangent(
        t: CGFloat,
        start: CGPoint,
        control: CGPoint,
        end: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: 2 * (1 - t) * (control.x - start.x) + 2 * t * (end.x - control.x),
            y: 2 * (1 - t) * (control.y - start.y) + 2 * t * (end.y - control.y)
        )
    }

    /// Pulls the curve toward the destination tab.
    static func controlPoint(from start: CGPoint, to end: CGPoint) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * 0.55,
            y: start.y + (end.y - start.y) * 0.35
        )
    }

    static func approximateLength(from start: CGPoint, to end: CGPoint) -> CGFloat {
        let control = controlPoint(from: start, to: end)
        var length: CGFloat = 0
        var previous = start
        for step in 1...lengthSamples {
            let t = CGFloat(step) / CGFloat(lengthSamples)
            let point = quadraticPoint(t: t, start: start, control: control, end: end)
            length += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
        }
        return length
    }

    static func chevronCount(forPathLength length: CGFloat) -> Int {
        guard length.isFinite, length > 0 else { return minCount }
        let raw = Int((length / spacing).rounded())
        return min(maxCount, max(minCount, raw))
    }

    static func samples(
        from start: CGPoint,
        to end: CGPoint,
        phase: CGFloat,
        count: Int? = nil
    ) -> [CTAChevronSample] {
        let length = approximateLength(from: start, to: end)
        let resolvedCount = count ?? chevronCount(forPathLength: length)
        guard resolvedCount > 0 else { return [] }
        let control = controlPoint(from: start, to: end)
        let wrappedPhase = wrap01(phase)
        let sizeScale = min(1.2, max(0.85, length / 420))
        return (0..<resolvedCount).map { index in
            let base = (CGFloat(index) + 0.5) / CGFloat(resolvedCount)
            let marched = wrap01(base + wrappedPhase / CGFloat(resolvedCount))
            let pathT = 0.06 + marched * 0.88
            let point = quadraticPoint(t: pathT, start: start, control: control, end: end)
            let tangent = quadraticTangent(t: pathT, start: start, control: control, end: end)
            let angle = atan2(tangent.y, tangent.x) + .pi / 2
            let size = (28 + pathT * 16) * sizeScale
            let opacity = 0.5 + Double(pathT) * 0.5
            return CTAChevronSample(point: point, angle: angle, size: size, opacity: opacity)
        }
    }

    static func wrap01(_ value: CGFloat) -> CGFloat {
        let truncated = value.truncatingRemainder(dividingBy: 1)
        return truncated < 0 ? truncated + 1 : truncated
    }
}
