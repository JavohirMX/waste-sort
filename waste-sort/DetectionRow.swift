import SwiftUI

struct DetectionRow: View {
    let className: String
    let confidence: Float

    private var bin: BinInfo { BinGuide.info(for: className) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2)
                .fill(bin.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bin.title)
                        .font(.system(.headline, design: .rounded))
                    Spacer()
                    Text(confidence, format: .percent.precision(.fractionLength(0)))
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(bin.bin)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(bin.color)

                Text(bin.instructions)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bin.title), \(bin.bin), \(Int(confidence * 100)) percent")
    }
}
