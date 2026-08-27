import SwiftUI

/// Destination-bin row: accuracy percent plus a correct vs misplaced ratio bar.
struct ThrownIntoRow: View {
    let bin: BinInfo
    let placement: StatsBinPlacement
    var metrics: StatsLayout.ThrownIntoMetrics

    private static let misplacedColor = Color(red: 0.95, green: 0.22, blue: 0.25)

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.labelBarSpacing) {
            HStack(alignment: .center, spacing: metrics.hStackSpacing) {
                Image(systemName: bin.symbolName)
                    .font(.system(size: metrics.iconSize, weight: .bold))
                    .foregroundStyle(bin.color)
                    .frame(width: metrics.iconFrame)

                Text(bin.displayName.capitalized)
                    .font(.system(size: metrics.nameSize, weight: .medium, design: .default))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)

                if placement.total > 0 {
                    Text("\(placement.correct) correct · \(placement.misplaced) misplaced")
                        .font(.system(size: metrics.countsSize, weight: .medium, design: .default).monospacedDigit())
                        .foregroundStyle(Color(white: 0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(0)
                }

                Spacer(minLength: 8)

                Text("\(placement.accuracyPercent)%")
                    .font(.system(size: metrics.percentSize, weight: .bold, design: .default).monospacedDigit())
                    .foregroundStyle(Color(white: 0.12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }

            if placement.total > 0 {
                splitBar
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
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
        .frame(height: metrics.barHeight)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let name = bin.displayName.capitalized
        let percent = placement.accuracyPercent
        return "\(name), \(percent) percent correct, \(placement.correct) correct, \(placement.misplaced) misplaced"
    }
}
