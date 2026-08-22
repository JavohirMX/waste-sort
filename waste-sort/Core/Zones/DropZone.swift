import CoreGraphics
import Foundation

/// A calibrated quad drawn over a physical bin, in normalized image space.
///
/// Corners live in the same space as `TrackedDetection.displayXywhn`: 0…1,
/// origin top-left, *unflipped*. Rendering applies `DetectionGeometry.flipNormalized180`
/// on the way out, so hit-testing here needs no view geometry at all.
nonisolated struct DropZone: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// `BinGuide` id: `organic`, `residual`, or `clean_inorganic`.
    var binID: String
    /// Exactly four corners, in drawing order (top-left, top-right, bottom-right, bottom-left).
    var corners: [CGPoint]

    init(id: UUID = UUID(), name: String, binID: String, corners: [CGPoint]) {
        self.id = id
        self.name = name
        self.binID = binID
        self.corners = corners
    }

    var bin: BinInfo { BinGuide.info(for: binID) }

    var centroid: CGPoint {
        guard !corners.isEmpty else { return .zero }
        let sum = corners.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(corners.count), y: sum.y / CGFloat(corners.count))
    }

    /// Even-odd ray cast, so concave quads (a dragged-through corner) still behave.
    func contains(_ point: CGPoint) -> Bool {
        guard corners.count >= 3 else { return false }
        var inside = false
        var j = corners.count - 1
        for i in corners.indices {
            let a = corners[i]
            let b = corners[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    /// Clamps every corner back into the frame after a drag.
    mutating func clampToFrame() {
        corners = corners.map {
            CGPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1))
        }
    }

    static func rect(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    /// One zone per waste category, tiled left-to-right across the lower half of the
    /// preview *as the operator sees it*.
    ///
    /// Corners are stored in image space, but the preview is rotated (180° by default),
    /// so laying the row out directly in image space puts the categories on screen in
    /// reverse — out of step with the category bar, which is plain HUD and never rotates.
    /// The row is therefore built in screen space and mapped back through the inverse of
    /// the preview transform.
    static func defaults(
        rotation: LivePreviewRotation = .zero,
        mirror: Bool = false
    ) -> [DropZone] {
        let bins = BinGuide.all
        guard !bins.isEmpty else { return [] }
        let gutter: CGFloat = 0.04
        let total = CGFloat(bins.count)
        let width = (1 - gutter * (total + 1)) / total
        return bins.enumerated().map { index, bin in
            let x = gutter + (width + gutter) * CGFloat(index)
            let onScreen = rect(CGRect(x: x, y: 0.42, width: width, height: 0.5))
            return DropZone(
                name: bin.displayName.capitalized,
                binID: bin.id,
                corners: onScreen.map { imageSpace($0, rotation: rotation, mirror: mirror) }
            )
        }
    }

    /// Inverse of the preview transform, which applies mirror then rotation.
    static func imageSpace(
        _ point: CGPoint,
        rotation: LivePreviewRotation,
        mirror: Bool
    ) -> CGPoint {
        let unrotated = DetectionGeometry.rotateNormalized(
            point,
            by: DetectionGeometry.inverse(rotation)
        )
        return mirror ? DetectionGeometry.mirrorNormalized(unrotated) : unrotated
    }
}
