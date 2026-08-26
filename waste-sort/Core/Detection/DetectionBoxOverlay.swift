import SwiftUI


/// Detection frames with subtle category fill, stroke, and corner badge.
struct DetectionBoxOverlay: View {
    let tracks: [TrackedDetection]
    let imageSize: CGSize
    let viewSize: CGSize
    var useAspectFill: Bool = true
    var rotation: LivePreviewRotation = .zero
    var mirror: Bool = false
    var style: BoxOverlayStyle = .default
    /// What the on-device confirmation layer is doing with each track. Empty when the layer
    /// is switched off, which draws exactly as it did before it existed.
    var confirmation: ConfirmationFrame = ConfirmationFrame()
    @EnvironmentObject private var binStyle: BinStyleStore

    var body: some View {
        ZStack {
            ForEach(tracks) { track in
                let rect = mappedRect(for: track)
                if rect.width > 1, rect.height > 1 {
                    let info = BinGuide.info(for: track.classKey)
                    let isDirty = info.id == BinGuide.dirtyRecyclable.id
                    DetectionBoxView(
                        bin: binStyle.resolved(isDirty ? BinGuide.residual : info),
                        recyclableBin: binStyle.resolved(BinGuide.cleanInorganic),
                        isDirtyRecyclable: isDirty,
                        rect: rect,
                        confidence: track.conf,
                        style: style,
                        isCoasting: track.isCoasting,
                        confirmation: confirmation.state(for: track.id),
                        isUncertain: track.beliefUncertain
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func mappedRect(for track: TrackedDetection) -> CGRect {
        DetectionGeometry.mapDisplayRect(
            normalized: track.displayXywhn,
            imageSize: imageSize,
            viewSize: viewSize,
            rotation: rotation,
            mirror: mirror,
            useAspectFill: useAspectFill
        )
    }
}
