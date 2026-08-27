import SwiftUI

struct DetectionSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    /// Sampled when the pane appears: the model can finish downloading between visits.
    @State private var confirmationAvailability = FoundationCategoryAvailability.current

    var body: some View {
        Form {
            demoSection
            modelSection
            detectionSection
            confirmationSection
        }
        .font(.system(.body, design: .default))
        .onAppear { confirmationAvailability = .current }
    }

    @ViewBuilder
    private var demoSection: some View {
        Section {
            Toggle("Demo mode", isOn: $settings.demoMode)
        } header: {
            Text("Demo")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text(
                "Uses the printed-photo weights so tabletop cards light the bins. "
                    + "Turns off on-device confirmation and lid detection — bins stay open. "
                    + "Cards that first appear over a bin still count as throws. "
                    + "Not for real waste."
            )
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section {
            Picker("Model", selection: $settings.selectedModelName) {
                if settings.demoMode {
                    Text(WasteSortModel.demo.displayName).tag(WasteSortModel.demo.resourceName)
                }
                ForEach(WasteSortModel.productionCases) { model in
                    Text(model.displayName).tag(model.resourceName)
                }
            }
            .disabled(settings.demoMode)
        } header: {
            Text("Model")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text(
                settings.demoMode
                    ? "Demo mode is using the printed-photo weights. Turn it off to pick a production model."
                    : "Changes reload Live and Photo sorting with the selected CoreML weights."
            )
        }
    }

    @ViewBuilder
    private var detectionSection: some View {
        Section {
            SettingsSliderRow(
                title: "Confidence",
                help: "How sure the model must be before showing an item. Higher = fewer boxes, more certain. Lower = more boxes, more mistakes.",
                valueText: SettingsFormat.percent(settings.confidence),
                value: $settings.confidence,
                range: 0.05...1.0,
                step: 0.05
            )
            SettingsSliderRow(
                title: "Overlap",
                help: "How much two boxes can overlap before one is dropped. Higher = fewer duplicate boxes. Lower = more overlapping boxes kept.",
                valueText: SettingsFormat.decimal(settings.iou),
                value: $settings.iou,
                range: 0.1...1.0,
                step: 0.05
            )
            SettingsIntSliderRow(
                title: "Max items",
                help: "Maximum number of items shown at once. Lower can be faster; higher finds more objects.",
                value: $settings.maxItems,
                range: 1...100
            )
        } header: {
            Text("Detection")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text("These affect live camera and photo sorting.")
        }
    }

    /// Kept out of the view body: as one concatenated literal in a `Text` it pushed the
    /// type checker past its budget and failed the build.
    private var confirmationFooter: String {
        """
        The detector keeps finding items as it does now. On top of that, each item is \
        photographed and shown to the on-device Foundation model, and whatever it answers is \
        locked in — the category stops changing for as long as that item stays on screen, and \
        it is what gets recorded when the item is thrown away. Its box breathes while the \
        model is thinking and flashes when the answer lands.

        When "Show last verdict on Live" is on, a chip shows the crop the model was \
        actually given; tap it for every answer this session, including the ones that were \
        not acted on.

        \(confirmationAvailability.summary)
        """
    }

    @ViewBuilder
    private var confirmationSection: some View {
        Section {
            Toggle("Confirm with on-device model", isOn: $settings.foundationConfirmationEnabled)
                .disabled(settings.demoMode)

            LabeledContent("Status") {
                Text(confirmationAvailability.isReady ? "Ready" : "Off")
                    .foregroundStyle(confirmationAvailability.isReady ? .green : .secondary)
            }

            Toggle("Show last verdict on Live", isOn: $settings.foundationVerdictLogEnabled)
                .disabled(!settings.foundationConfirmationEnabled)
        } header: {
            Text("Category confirmation")
                .foregroundStyle(BinGuide.cleanInorganic.color)
        } footer: {
            Text(confirmationFooter)
        }
    }
}
