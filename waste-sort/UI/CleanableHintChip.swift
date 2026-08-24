import SwiftUI

/// Shown when an item is heading for residual only because it is dirty — the one outcome
/// the user can still change, by rinsing it. The design pairs the two bins it sits between
/// in a single split token so the chip reads without being labelled twice.
struct CleanableHintChip: View {
    @Environment(\.hudTextScale) private var scale

    var body: some View {
        HStack(spacing: 8 * scale) {
            splitToken

            Text("If cleaned, can be ")
                .foregroundStyle(.white.opacity(0.85))
                + Text("Recyclable")
                .foregroundStyle(.white)
                .fontWeight(.semibold)
        }
        .font(.system(size: 13 * scale, weight: .regular, design: .default))
        .padding(.leading, 8 * scale)
        .padding(.trailing, 14 * scale)
        .padding(.vertical, 7 * scale)
        .background(Color.black.opacity(0.75), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("If cleaned, this can be recyclable")
    }

    /// One circle carrying both bins: residual on the upper left, inorganic on the lower
    /// right, split along the diagonal.
    private var splitToken: some View {
        let side = 26.0 * scale
        return ZStack {
            Circle().fill(BinGuide.residual.color)
            Circle()
                .fill(BinGuide.cleanInorganic.color)
                .clipShape(LowerRightTriangle())

            Image(systemName: "trash.fill")
                .font(.system(size: 8 * scale, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: -side * 0.19, y: -side * 0.19)

            Image(systemName: "arrow.3.trianglepath")
                .font(.system(size: 8 * scale, weight: .bold))
                .foregroundStyle(BinGuide.residual.color)
                .offset(x: side * 0.19, y: side * 0.19)
        }
        .frame(width: side, height: side)
    }
}

/// The half below the bottom-left → top-right diagonal.
private struct LowerRightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack {
        Color.gray
        CleanableHintChip()
    }
    .ignoresSafeArea()
}
