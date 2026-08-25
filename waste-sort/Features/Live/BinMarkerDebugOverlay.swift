import SwiftUI

/// Shows what the marker scanner is actually seeing.
///
/// This is the feature's tuning instrument, not decoration. Two strip styles exist precisely
/// because which one survives a real room cannot be decided from a desk, and choosing between
/// them means being able to read, at the bins: is the strip found, is its rhythm legible or is
/// it coasting on ink alone, and how many samples wide a printed unit lands.
struct BinMarkerDebugOverlay: View {
    var frame: BinMarkerStatusFrame
    var zones: [DropZone]
    var style: BinMarkerStyle
    var imageSize: CGSize
    var viewSize: CGSize
    var rotation: LivePreviewRotation
    var mirror: Bool
    /// Nil hides the calibrate control — there is nothing to learn from an empty frame.
    var onCalibrate: (() -> Void)?

    var body: some View {
        if viewSize.width > 0, viewSize.height > 0 {
            ZStack {
                ForEach(Array(frame.detections.enumerated()), id: \.offset) { _, detection in
                    let rect = toViewSpace(detection.bounds)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(color(for: detection), lineWidth: detection.isDegraded ? 2 : 3)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    Text(label(for: detection))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(color(for: detection).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        .position(x: rect.midX, y: max(10, rect.minY - 10))
                }

                ForEach(Array(frame.rows.enumerated()), id: \.offset) { _, row in
                    let rect = toViewSpace(row.bounds)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.green, lineWidth: 3)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    // Dashes first, because that is the number the whole style turns on: five
                    // is the floor, and more of them means more of the drawer is out.
                    Text(String(format: "%d dashes  %.1fpx ×%d",
                                row.dashes, row.pitchSamples, row.lineCount))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        .position(x: rect.midX, y: max(10, rect.minY - 10))
                }

                ForEach(zones) { zone in
                    if let status = frame.statuses[zone.id] {
                        let center = toViewSpace(centroid(of: zone))
                        HStack(spacing: 4) {
                            Circle()
                                .fill(status.state == .open ? Color.green : Color.red)
                                .frame(width: 6, height: 6)
                            Text(badge(for: status))
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .position(x: center.x, y: center.y - 20)
                    }
                }

                if let stats = frame.stats {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(stats.sourceWidth)x\(stats.sourceHeight)  \(Int(stats.detectionMilliseconds))ms")
                        Text("candidates \(stats.candidateCount)  accepted \(stats.acceptedCount)")
                        // The number to watch when placing or resizing a print: below about
                        // three samples per unit the bar widths stop meaning anything, and the
                        // mono style loses the bin entirely.
                        Text("unit px \(stats.largestUnitSamples.map { String(format: "%.1f", $0) } ?? "-")")
                        if stats.missingChroma {
                            Text("NO CHROMA — colour style cannot run")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                }

                if let onCalibrate, style == .color, !frame.detections.isEmpty {
                    Button("Calibrate colors", action: onCalibrate)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                }
            }
        }
    }

    private func color(for detection: BinMarkerDetection) -> Color {
        guard let slot = detection.slot(style: style) else { return .orange }
        let ink = slot.ink
        return Color(
            red: Double(ink.red) / 255,
            green: Double(ink.green) / 255,
            blue: Double(ink.blue) / 255
        )
    }

    /// Two numbers, and they answer the two ways a marker gets printed wrong.
    ///
    /// `unit` is samples per printed unit — too few and the bar widths stop separating, which
    /// costs the rhythm first and the strip second. The line count is how many scan lines
    /// crossed it, which is the *thickness* the camera sees: three is the floor, and a marker
    /// hovering there wants a taller print or a nearer camera.
    private func label(for detection: BinMarkerDetection) -> String {
        guard let slot = detection.slot(style: style) else { return "?" }
        let identity = detection.isDegraded ? "M\(slot.index + 1) ink" : "M\(slot.index + 1)"
        return String(format: "%@ %.1fpx ×%d", identity, detection.unitSamples, detection.lineCount)
    }

    private func badge(for status: BinMarkerOpenness) -> String {
        guard status.state == .open else { return "CLOSED" }
        if status.isCoasting { return "OPEN (held)" }
        return status.isDegraded ? "OPEN (ink)" : "OPEN"
    }

    private func centroid(of zone: DropZone) -> CGPoint {
        guard !zone.corners.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let sum = zone.corners.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(zone.corners.count), y: sum.y / CGFloat(zone.corners.count))
    }

    private func toViewSpace(_ normalized: CGRect) -> CGRect {
        let corners = [
            CGPoint(x: normalized.minX, y: normalized.minY),
            CGPoint(x: normalized.maxX, y: normalized.minY),
            CGPoint(x: normalized.maxX, y: normalized.maxY),
            CGPoint(x: normalized.minX, y: normalized.maxY)
        ].map { toViewSpace($0) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func toViewSpace(_ normalized: CGPoint) -> CGPoint {
        DetectionGeometry.mapDisplayPoint(
            normalized: normalized,
            imageSize: imageSize,
            viewSize: viewSize,
            rotation: rotation,
            mirror: mirror,
            useAspectFill: true
        )
    }
}
