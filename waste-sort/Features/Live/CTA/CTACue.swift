import CoreGraphics
import Foundation

/// One live detection mapped into view space for CTA overlays.
struct CTACue: Equatable, Identifiable {
    let id: Int
    let binID: String
    let displayRect: CGRect
}

enum CTACueMapper {
    /// Maps confirmed tracks to CTA cues, skipping unknown classes and tiny boxes.
    static func cues(
        from tracks: [TrackedDetection],
        imageSize: CGSize,
        viewSize: CGSize,
        rotation: LivePreviewRotation,
        mirror: Bool,
        useAspectFill: Bool = true
    ) -> [CTACue] {
        tracks.compactMap { track in
            guard !track.isCoasting else { return nil }
            let bin = BinGuide.info(for: track.classKey)
            guard bin.id != BinGuide.unknown.id else { return nil }
            let rect = DetectionGeometry.mapDisplayRect(
                normalized: track.displayXywhn,
                imageSize: imageSize,
                viewSize: viewSize,
                rotation: rotation,
                mirror: mirror,
                useAspectFill: useAspectFill
            )
            guard rect.width > 1, rect.height > 1 else { return nil }
            return CTACue(id: track.id, binID: bin.id, displayRect: rect)
        }
    }

    static func activeBinIDs(from cues: [CTACue]) -> Set<String> {
        Set(cues.map(\.binID))
    }
}
