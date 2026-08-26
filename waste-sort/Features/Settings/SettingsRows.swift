import SwiftUI

enum SettingsFormat {
    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func signedDecimal(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }
}

struct SettingsPickerRow: View {
    let title: String
    let help: String
    @Binding var isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 8)
                Picker(title, selection: $isLocked) {
                    Text("Auto").tag(false)
                    Text("Locked").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            Text(help)
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsSliderRow: View {
    let title: String
    let help: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // Keep the slider its own accessibility element so VoiceOver can
            // adjust it; combining the row would collapse it to static text.
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
                .accessibilityHint(help)
            Text(help)
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct SettingsIntSliderRow: View {
    let title: String
    let help: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        SettingsSliderRow(
            title: title,
            help: help,
            valueText: "\(value)",
            value: Binding(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            ),
            range: Double(range.lowerBound)...Double(range.upperBound),
            step: 1
        )
    }
}
