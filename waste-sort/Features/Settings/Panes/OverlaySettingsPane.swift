import SwiftUI

struct OverlaySettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                badgeRows
                Toggle("Show FPS", isOn: $settings.showFPS)
                Toggle("Speak bin on deposit", isOn: $settings.voiceGuidanceEnabled)
                Toggle("Scan product barcodes", isOn: $settings.barcodeAssistEnabled)
                Toggle("Show last deposit on Live", isOn: $settings.showLastDepositOnLive)
                Toggle("Throw feedback sounds", isOn: $settings.throwFeedbackSoundsEnabled)
            } header: {
                Text("Live overlay")
                    .foregroundStyle(BinGuide.organic.color)
            } footer: {
                Text(overlayFooter)
            }
        }
        .font(.system(.body, design: .default))
    }

    @ViewBuilder
    private var badgeRows: some View {
        Picker("Style", selection: $settings.ctaStyle) {
            ForEach(CTAStyle.allCases) { style in
                Text(style.displayName).tag(style)
            }
        }
        Toggle("Icon", isOn: $settings.showBoxIcon)
        Toggle("Category", isOn: $settings.showBoxCategory)
        Toggle("Confidence", isOn: $settings.showConfidence)
        Picker("Placement", selection: $settings.boxLabelPlacement) {
            ForEach(BoxLabelPlacement.allCases) { placement in
                Text(placement.displayName).tag(placement)
            }
        }
        .disabled(!settings.boxOverlayStyle.showsBadge)
        SettingsSliderRow(
            title: "Box label size",
            help: "Scales the icon and text on each detection box.",
            valueText: "\(Int((settings.boxBadgeScale * 100).rounded()))%",
            value: $settings.boxBadgeScale,
            range: 0.75...2.0,
            step: 0.05
        )
        .disabled(!settings.boxOverlayStyle.showsBadge)
        SettingsSliderRow(
            title: "Category size",
            help: "Scales the three top-bar names and their icons together.",
            valueText: "\(Int((settings.hudTextScale * 100).rounded()))%",
            value: $settings.hudTextScale,
            range: 0.75...3.0,
            step: 0.05
        )
    }

    private var overlayFooter: String {
        "Shown on the live camera when waste is detected. Choose one visual guide at a time. "
            + "Box badges can show an icon, category name, and confidence percent; placement moves the badge around each box. "
            + "Show FPS draws a plain FPS label on the live camera, bottom left. "
            + "Voice guidance speaks which bin received a deposit - useful when the screen is hard to see from where you stand. "
            + "The last-deposit chip is a developer overlay; tap it for this session's deposits. History also lives in Stats. "
            + "Throw feedback sounds play on a scored throw even if the silent switch is on."
    }
}
