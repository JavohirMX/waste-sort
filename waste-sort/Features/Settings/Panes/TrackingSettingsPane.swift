import SwiftUI

struct TrackingSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                enginePicker
                identityRows
                beliefRows
                motionRows
                Toggle("Verbose detection log", isOn: $settings.verboseDetectionLogging)
            } header: {
                Text("Live tracking")
                    .foregroundStyle(BinGuide.cleanInorganic.color)
            } footer: {
                Text(
                    "Verdict certainty and margin only act on the Belief engine; unsure items are guided to the residual bin. "
                        + "Legacy confidence replays the old math with no uncertainty concept, and appearance/recheck assists go inert. "
                        + "Verbose logging writes every tracked frame to the session CSV for offline replay."
                )
            }
        }
        .font(.system(.body, design: .default))
    }

    private var enginePicker: some View {
        Picker("Decision engine", selection: $settings.decisionPipeline) {
            ForEach(DecisionPipeline.allCases, id: \.self) { pipeline in
                Text(pipeline.displayName).tag(pipeline)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var identityRows: some View {
        SettingsIntSliderRow(
            title: "Confirm frames",
            help: "How many frames an item must appear before it shows. Higher = fewer false flashes, slower to appear.",
            value: $settings.confirmHits,
            range: 1...10
        )
        SettingsIntSliderRow(
            title: "Keep after miss",
            help: "How many frames a box stays after the model loses it. Boxes freeze in place (no sliding). Higher = boxes linger more.",
            value: $settings.maxMisses,
            range: 1...20
        )
        SettingsSliderRow(
            title: "Same-item overlap",
            help: "How much two detections must overlap to count as the same item across frames.",
            valueText: SettingsFormat.decimal(settings.trackerIou),
            value: $settings.trackerIou,
            range: 0.1...0.9,
            step: 0.05
        )
        SettingsSliderRow(
            title: "Class-change overlap",
            help: "How much a relabelled box must overlap to stay the same item. Cannot be tighter than Same-item overlap.",
            valueText: SettingsFormat.decimal(settings.crossClassIou),
            value: $settings.crossClassIou,
            range: 0.1...0.9,
            step: 0.05
        )
    }

    @ViewBuilder
    private var beliefRows: some View {
        SettingsSliderRow(
            title: "Verdict certainty",
            help: "How sure the app must be before it commits to a bin. "
                + "Higher = fewer confident mistakes, more 'not sure' items.",
            valueText: SettingsFormat.percent(settings.beliefThreshold),
            value: $settings.beliefThreshold,
            range: 0.30...0.95,
            step: 0.05
        )
        SettingsSliderRow(
            title: "Verdict margin",
            help: "How far the leading category must sit ahead of the runner-up. "
                + "Higher = borderline items are treated as unsure instead of guessed.",
            valueText: SettingsFormat.decimal(settings.beliefMargin),
            value: $settings.beliefMargin,
            range: 0.00...0.60,
            step: 0.05
        )
    }

    @ViewBuilder
    private var motionRows: some View {
        SettingsSliderRow(
            title: "Smoothing",
            help: "How quickly boxes follow movement. Higher = snappier. Lower = smoother but laggy.",
            valueText: SettingsFormat.decimal(settings.emaAlpha),
            value: $settings.emaAlpha,
            range: 0.05...1.0,
            step: 0.05
        )
        SettingsSliderRow(
            title: "Box padding",
            help: "Extra space around each box. Higher = larger boxes.",
            valueText: SettingsFormat.percent(settings.boxInflate),
            value: $settings.boxInflate,
            range: 0...0.3,
            step: 0.01
        )
        SettingsSliderRow(
            title: "Max jump speed",
            help: "How far a box can move in one second. Lower = less teleporting, more likely to drop fast moves.",
            valueText: String(format: "%.1f", settings.maxSpeed),
            value: $settings.maxSpeed,
            range: 0.5...5.0,
            step: 0.1
        )
    }
}
