import SwiftUI

/// Draws calibrated drop zones over the live preview.
///
/// Corners are stored untransformed in image space and go through the same
/// rotation/mirror/aspect-fill mapping as the detection boxes.
///
/// Outside calibration the zones stay hidden so they do not clutter the live feed —
/// only a zone that is occupied, settling, or has just taken a deposit is drawn.
/// `showZones` hides even those, while editing still shows every outline.
struct ZoneOverlayView: View {
    let zones: [DropZone]
    let imageSize: CGSize
    let viewSize: CGSize
    var rotation: LivePreviewRotation = .zero
    var mirror = false
    var isEditing = false
    var showZones = true
    var selectedZoneID: UUID?
    /// Zones that just took a deposit — shown briefly even when calibration is off.
    var flashedZoneIDs: Set<UUID> = []
    /// Zones with an item inside right now — outlined, not filled.
    var occupiedZoneIDs: Set<UUID> = []
    /// Occupied zones whose item has met the dwell requirement.
    var armedZoneIDs: Set<UUID> = []
    /// Zones whose item has vanished and is inside its reacquisition window — the deposit
    /// is pending, waiting to see whether the model finds it again.
    var settlingZoneIDs: Set<UUID> = []
    var onMoveCorner: ((UUID, Int, CGPoint) -> Void)?
    var onMoveZone: ((UUID, [CGPoint]) -> Void)?
    var onSelectZone: ((UUID) -> Void)?

    /// Corner snapshot taken when a whole-zone drag begins, so the move never drifts.
    @State private var dragOrigin: [UUID: [CGPoint]] = [:]

    var body: some View {
        ZStack {
            ForEach(visibleZones) { zone in
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

    private var visibleZones: [DropZone] {
        guard !isEditing else { return zones }
        guard showZones else { return [] }
        return zones.filter {
            flashedZoneIDs.contains($0.id)
                || occupiedZoneIDs.contains($0.id)
                || settlingZoneIDs.contains($0.id)
        }
    }

    private func isActive(_ zone: DropZone) -> Bool {
        !isEditing || selectedZoneID == nil || selectedZoneID == zone.id
    }

    private struct ZoneStyle {
        var fill: Double
        var stroke: Double
        var lineWidth: CGFloat
        var dash: [CGFloat]
    }

    /// Four states the operator needs to tell apart at a glance: being calibrated, holding
    /// an item right now, waiting out the reacquisition window after one vanished, and
    /// having just recorded one.
    private func style(for zone: DropZone) -> ZoneStyle {
        if flashedZoneIDs.contains(zone.id) {
            // Deposited: solid and filled.
            return ZoneStyle(
                fill: Theme.zoneFlashFillOpacity,
                stroke: 1,
                lineWidth: Theme.zoneStrokeWidth * 1.4,
                dash: []
            )
        }
        if isEditing {
            let active = isActive(zone)
            return ZoneStyle(
                fill: active ? Theme.zoneFillOpacity : Theme.zoneFillOpacity * 0.4,
                stroke: active ? 1 : 0.45,
                lineWidth: Theme.zoneStrokeWidth,
                dash: Theme.zoneEditDash
            )
        }
        if settlingZoneIDs.contains(zone.id) {
            // The item is gone but not yet judged. A faint fill says "counting this",
            // without the commitment of the deposit flash it may never earn.
            return ZoneStyle(
                fill: Theme.zoneFillOpacity,
                stroke: 0.9,
                lineWidth: Theme.zoneStrokeWidth,
                dash: Theme.zoneArmedDash
            )
        }
        // Occupied: dashed outline only. Tighter dashes once the dwell is met, so
        // "would count if dropped now" is visible without a second colour.
        let armed = armedZoneIDs.contains(zone.id)
        return ZoneStyle(
            fill: 0,
            stroke: armed ? 0.95 : 0.6,
            lineWidth: Theme.zoneStrokeWidth,
            dash: armed ? Theme.zoneArmedDash : Theme.zoneOccupiedDash
        )
    }

    private func path(_ points: [CGPoint]) -> Path {
        Path { path in
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
    }

    private func shape(for zone: DropZone, points: [CGPoint]) -> some View {
        let outline = path(points)
        let style = style(for: zone)

        return ZStack {
            outline.fill(zone.bin.color.opacity(style.fill))
            outline.stroke(
                zone.bin.color.opacity(style.stroke),
                style: StrokeStyle(
                    lineWidth: style.lineWidth,
                    lineJoin: .round,
                    dash: style.dash
                )
            )
        }
        // Dragging anywhere inside the quad moves the whole zone. Without this a zone
        // whose corners sit outside the cropped preview could not be reached at all.
        // Hit testing as a whole is gated by `allowsHitTesting(isEditing)` above.
        .contentShape(outline)
        // Tap picks which zone is being edited. The drag needs 4pt of movement, so a
        // stationary touch resolves as a tap; simultaneous rather than a plain
        // onTapGesture so neither gesture can claim priority over the other.
        .simultaneousGesture(TapGesture().onEnded { onSelectZone?(zone.id) })
        .gesture(moveGesture(for: zone))
    }

    private func moveGesture(for zone: DropZone) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = dragOrigin[zone.id] ?? zone.corners
                if dragOrigin[zone.id] == nil {
                    dragOrigin[zone.id] = start
                    onSelectZone?(zone.id)
                }
                // Convert both endpoints to image space so rotation and mirroring
                // are handled by the same mapping the corners use.
                let from = normalized(from: value.startLocation, clamped: false)
                let to = normalized(from: value.location, clamped: false)
                let delta = CGPoint(x: to.x - from.x, y: to.y - from.y)
                onMoveZone?(zone.id, translate(start, by: delta))
            }
            .onEnded { _ in
                dragOrigin[zone.id] = nil
            }
    }

    /// Shifts every corner, pulling the delta back so the quad cannot leave the frame.
    private func translate(_ corners: [CGPoint], by delta: CGPoint) -> [CGPoint] {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let dx = min(max(delta.x, -minX), 1 - maxX)
        let dy = min(max(delta.y, -minY), 1 - maxY)
        return corners.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
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

    private func normalized(from viewPoint: CGPoint, clamped: Bool = true) -> CGPoint {
        let point = DetectionGeometry.mapNormalizedPoint(
            viewPoint: viewPoint,
            imageSize: imageSize,
            viewSize: viewSize,
            rotation: rotation,
            mirror: mirror,
            useAspectFill: true
        )
        guard clamped else { return point }
        return CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}
