import SwiftUI

/// Draws calibrated drop zones over the live preview, optionally with draggable corners.
///
/// Corners are stored untransformed in image space and go through the same
/// rotation/mirror/aspect-fill mapping as the detection boxes.
struct ZoneOverlayView: View {
    let zones: [DropZone]
    let imageSize: CGSize
    let viewSize: CGSize
    var rotation: LivePreviewRotation = .zero
    var mirror = false
    var isEditing = false
    var selectedZoneID: UUID?
    /// Zones that just took a deposit — briefly brightened as confirmation.
    var flashedZoneIDs: Set<UUID> = []
    var onMoveCorner: ((UUID, Int, CGPoint) -> Void)?

    var body: some View {
        ZStack {
            ForEach(zones) { zone in
                let points = viewPoints(for: zone)
                if points.count == zone.corners.count, points.count >= 3 {
                    shape(for: zone, points: points)
                    label(for: zone, points: points)
                    // Only the focused zone shows handles, so overlapping bins
                    // do not stack draggable dots on top of each other.
                    if isEditing, isActive(zone) {
                        handles(for: zone, points: points)
                    }
                }
            }
        }
        .allowsHitTesting(isEditing)
    }

    private func isActive(_ zone: DropZone) -> Bool {
        !isEditing || selectedZoneID == nil || selectedZoneID == zone.id
    }

    private func shape(for zone: DropZone, points: [CGPoint]) -> some View {
        let path = Path { path in
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        let active = isActive(zone)
        let flashed = flashedZoneIDs.contains(zone.id)
        let fill = flashed
            ? Theme.zoneFlashFillOpacity
            : (active ? Theme.zoneFillOpacity : Theme.zoneFillOpacity * 0.4)
        return ZStack {
            path.fill(zone.bin.color.opacity(fill))
            path.stroke(
                zone.bin.color.opacity(active ? 1 : 0.45),
                style: StrokeStyle(
                    lineWidth: Theme.zoneStrokeWidth,
                    lineJoin: .round,
                    dash: isEditing ? [10, 6] : []
                )
            )
        }
    }

    private func label(for zone: DropZone, points: [CGPoint]) -> some View {
        let center = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / CGFloat(points.count), y: $0.y + $1.y / CGFloat(points.count))
        }
        return HStack(spacing: 5) {
            Image(systemName: zone.bin.symbolName)
                .font(.system(size: 11, weight: .bold))
            Text(zone.name.uppercased())
                .font(.system(.caption2, design: .default).weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(zone.bin.color.opacity(0.9), in: Capsule())
        .position(center)
        .allowsHitTesting(false)
    }

    private func handles(for zone: DropZone, points: [CGPoint]) -> some View {
        ForEach(points.indices, id: \.self) { index in
            Circle()
                .fill(.white)
                .overlay { Circle().strokeBorder(zone.bin.color, lineWidth: 3) }
                .frame(width: Theme.zoneHandleSize, height: Theme.zoneHandleSize)
                .shadow(radius: 3)
                .contentShape(Circle().inset(by: -Theme.zoneHandleSize * 0.5))
                .position(points[index])
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onMoveCorner?(zone.id, index, normalized(from: value.location))
                        }
                )
        }
    }

    private func viewPoints(for zone: DropZone) -> [CGPoint] {
        zone.corners.map {
            DetectionGeometry.mapDisplayPoint(
                normalized: $0,
                imageSize: imageSize,
                viewSize: viewSize,
                rotation: rotation,
                mirror: mirror,
                useAspectFill: true
            )
        }
    }

    private func normalized(from viewPoint: CGPoint) -> CGPoint {
        let point = DetectionGeometry.mapNormalizedPoint(
            viewPoint: viewPoint,
            imageSize: imageSize,
            viewSize: viewSize,
            rotation: rotation,
            mirror: mirror,
            useAspectFill: true
        )
        return CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}
