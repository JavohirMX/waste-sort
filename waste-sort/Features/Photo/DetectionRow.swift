import SwiftUI

struct DetectionRow: View {
    let className: String
    let confidence: Float
    @EnvironmentObject private var binStyle: BinStyleStore

    private var bin: BinInfo { binStyle.resolved(BinGuide.info(for: className)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(bin.color)
                        .frame(width: 36, height: 36)
                    Image(systemName: bin.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bin.displayName)
                            .font(.system(.headline, design: .default).weight(.semibold))
                            .tracking(0.4)
                        Spacer()
                        Text(confidence, format: .percent.precision(.fractionLength(0)))
                            .font(.system(.subheadline, design: .default).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(bin.bin)
                        .font(.system(.subheadline, design: .default))
                        .foregroundStyle(bin.id == BinGuide.residual.id ? Color.primary.opacity(0.7) : bin.color)
                }
            }

            Text(bin.instructions)
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bin.displayName), \(bin.bin), \(Int(confidence * 100)) percent")
    }
}
