import SwiftUI

/// Debug overlay to visualize detected AprilTags and per-zone openness status on top of camera feed.
struct AprilTagDebugOverlay: View {
    var detectedTags: [TrackedAprilTag]
    var statuses: [UUID: BinOpenness]
    var zones: [DropZone]
    var imageSize: CGSize
    var viewSize: CGSize
    var rotation: LivePreviewRotation
    var mirror: Bool

    init(
        detectedTags: [TrackedAprilTag],
        statuses: [UUID: BinOpenness],
        zones: [DropZone],
        imageSize: CGSize,
        viewSize: CGSize,
        rotation: LivePreviewRotation = .oneEighty,
        mirror: Bool = false
    ) {
        self.detectedTags = detectedTags
        self.statuses = statuses
        self.zones = zones
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.rotation = rotation
        self.mirror = mirror
    }

    var body: some View {
        guard viewSize.width > 0, viewSize.height > 0 else { return AnyView(EmptyView()) }

        return AnyView(
            ZStack {
                // Draw detected AprilTag corner boxes
                ForEach(detectedTags) { tag in
                    let corners = tag.corners.map { toViewSpace($0) }
                    if corners.count == 4 {
                        Path { path in
                            path.move(to: corners[0])
                            for point in corners.dropFirst() {
                                path.addLine(to: point)
                            }
                            path.closeSubpath()
                        }
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                        let center = toViewSpace(tag.center)
                        Text("#\(tag.id)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                            .position(center)
                    }
                }

                // Draw zone openness badges
                ForEach(zones) { zone in
                    if let status = statuses[zone.id] {
                        let center = toViewSpace(zoneCenter(zone))
                        HStack(spacing: 4) {
                            Circle()
                                .fill(status.state == .open ? Color.green : Color.red)
                                .frame(width: 6, height: 6)
                            Text(status.state == .open ? "OPEN" : "CLOSED")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .position(x: center.x, y: center.y - 20)
                    }
                }
            }
            .allowsHitTesting(false)
        )
    }

    private func zoneCenter(_ zone: DropZone) -> CGPoint {
        guard !zone.corners.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let sum = zone.corners.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(zone.corners.count), y: sum.y / CGFloat(zone.corners.count))
    }

    private func toViewSpace(_ normalizedPoint: CGPoint) -> CGPoint {
        var norm = normalizedPoint
        if mirror {
            norm = CGPoint(x: 1.0 - norm.x, y: norm.y)
        }
        norm = DetectionGeometry.rotateNormalized(norm, by: rotation)
        return CGPoint(x: norm.x * viewSize.width, y: norm.y * viewSize.height)
    }
}
