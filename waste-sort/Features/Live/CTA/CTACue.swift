import CoreGraphics
import Foundation

/// One live detection mapped into view space for CTA overlays.
struct CTACue: Equatable, Identifiable {
    let trackID: Int
    let binID: String
    let displayRect: CGRect

    var id: String { "\(trackID)-\(binID)" }
}

enum CTACueMapper {
    /// Maps confirmed tracks to CTA cues, skipping unknown classes and tiny boxes.
    /// Dirty recyclable emits one cue per physical bin it lights (residual and recyclable).
    static func cues(
        from tracks: [TrackedDetection],
        imageSize: CGSize,
        viewSize: CGSize,
        rotation: LivePreviewRotation,
        mirror: Bool,
        useAspectFill: Bool = true
    ) -> [CTACue] {
        tracks.flatMap { track -> [CTACue] in
            guard !track.isCoasting else { return [] }
            // Unsure items are pointed at the fallback stream, never the label's bin(s);
            // dirty recyclable legitimately cues two bars via `barBinIDs`.
            let binIDs = track.beliefUncertain
                ? [BinGuide.fallbackBinID]
                : BinGuide.barBinIDs(for: track.classKey)
            guard !binIDs.isEmpty else { return [] }
            let rect = DetectionGeometry.mapDisplayRect(
                normalized: track.displayXywhn,
                imageSize: imageSize,
                viewSize: viewSize,
                rotation: rotation,
                mirror: mirror,
                useAspectFill: useAspectFill
            )
            guard rect.width > 1, rect.height > 1 else { return [] }
            return binIDs.map { CTACue(trackID: track.id, binID: $0, displayRect: rect) }
        }
    }
}

extension CTACueMapper {
    /// Distinct bins the current cues point at, for bar highlighting.
    static func activeBinIDs(from cues: [CTACue]) -> Set<String> {
        Set(cues.map(\.binID))
    }
}
