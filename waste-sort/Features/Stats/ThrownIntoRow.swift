import SwiftUI

/// Destination-bin row: accuracy percent plus a correct vs misplaced ratio bar.
struct ThrownIntoRow: View {
    let bin: BinInfo
    let placement: StatsBinPlacement
    var isWide: Bool

    private static let misplacedColor = Color(red: 0.95, green: 0.22, blue: 0.25)

    var body: some View {
        VStack(alignment: .leading, spacing: isWide ? 10 : 8) {
            HStack(alignment: .center, spacing: isWide ? 12 : 10) {
                Image(systemName: bin.symbolName)
                    .font(.system(size: isWide ? 22 : 18, weight: .bold))
                    .foregroundStyle(bin.color)
                    .frame(width: isWide ? 28 : 22)

                Text(bin.displayName.capitalized)
                    .font(.system(size: isWide ? 22 : 15, weight: .medium, design: .default))
                    .foregroundStyle(.primary)
                    .layoutPriority(1)

                if placement.total > 0 {
                    Text("\(placement.correct) correct · \(placement.misplaced) misplaced")
                        .font(.system(size: isWide ? 16 : 12, weight: .medium, design: .default).monospacedDigit())
                        .foregroundStyle(Color(white: 0.45))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(placement.accuracyPercent)%")
                    .font(.system(size: isWide ? 22 : 18, weight: .bold, design: .default).monospacedDigit())
                    .foregroundStyle(Color(white: 0.12))
            }

            if placement.total > 0 {
                splitBar
            }
        }
        .padding(.horizontal, isWide ? 20 : 14)
        .padding(.vertical, isWide ? 12 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var splitBar: some View {
        Canvas { context, size in
            let correctWidth = size.width * CGFloat(placement.correct) / CGFloat(placement.total)
            context.fill(
                Path(CGRect(x: 0, y: 0, width: correctWidth, height: size.height)),
                with: .color(bin.color)
            )
            context.fill(
                Path(CGRect(x: correctWidth, y: 0, width: size.width - correctWidth, height: size.height)),
                with: .color(Self.misplacedColor)
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: isWide ? 10 : 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let name = bin.displayName.capitalized
        let percent = placement.accuracyPercent
        return "\(name), \(percent) percent correct, \(placement.correct) correct, \(placement.misplaced) misplaced"
    }
}
