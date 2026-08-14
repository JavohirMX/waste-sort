import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recording: RecordingController
    @State private var cameraOptions: [CameraOption] = CameraDeviceCatalog.availableOptions()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $settings.selectedModelName) {
                        ForEach(WasteSortModel.allCases) { model in
                            Text(model.displayName).tag(model.resourceName)
                        }
                    }
                } header: {
                    Text("Model")
                        .foregroundStyle(BinGuide.organic.color)
                } footer: {
                    Text("Changes reload Live and Photo sorting with the selected CoreML weights.")
                }

                Section {
                    Picker("Camera", selection: $settings.preferredCameraID) {
                        Text("Auto (prefer USB)").tag(CameraPreference.autoID)
                        ForEach(cameraOptions) { option in
                            Text("\(option.name) · \(option.subtitle)").tag(option.id)
                        }
                    }
                    .onChange(of: settings.preferredCameraID) { _, newValue in
                        if newValue != CameraPreference.autoID,
                           !cameraOptions.contains(where: { $0.id == newValue })
                        {
                            settings.preferredCameraID = CameraPreference.autoID
                        }
                    }
                } header: {
                    Text("Camera")
                        .foregroundStyle(BinGuide.residual.color)
                } footer: {
                    Text("Auto uses a connected USB-C webcam when available, otherwise the iPad back camera. Plug in a UVC webcam and reopen Settings if it does not appear.")
                }

                Section {
                    if recording.canStop {
                        Button("Stop recording", role: .destructive) {
                            recording.stopRecording()
                        }
                        HStack(spacing: 8) {
                            Circle()
                                .fill(recording.isRecording ? Color.red : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(recording.isRecording ? "Recording camera feed…" : "Starting…")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.footnote, design: .default))
                    } else {
                        Button("Start recording") {
                            recording.startRecording()
                        }
                        .disabled(!recording.canStart)
                    }

                    if let status = recording.statusMessage {
                        Text(status)
                            .font(.system(.footnote, design: .default))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recording")
                        .foregroundStyle(Color.red.opacity(0.85))
                } footer: {
                    Text(
                        recording.hasLiveSession
                            ? "Records the camera feed only (no overlays). Saves to Photos when you stop, or if the app is backgrounded or closed."
                            : "Open the Live tab first so the camera session is available."
                    )
                }

                Section {
                    SettingsSliderRow(
                        title: "Confidence",
                        help: "How sure the model must be before showing an item. Higher = fewer boxes, more certain. Lower = more boxes, more mistakes.",
                        valueText: percent(settings.confidence),
                        value: $settings.confidence,
                        range: 0.05...1.0,
                        step: 0.05
                    )
                    SettingsSliderRow(
                        title: "Overlap",
                        help: "How much two boxes can overlap before one is dropped. Higher = fewer duplicate boxes. Lower = more overlapping boxes kept.",
                        valueText: decimal(settings.iou),
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

                Section {
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
                        valueText: decimal(settings.trackerIou),
                        value: $settings.trackerIou,
                        range: 0.1...0.9,
                        step: 0.05
                    )
                    SettingsSliderRow(
                        title: "Smoothing",
                        help: "How quickly boxes follow movement. Higher = snappier. Lower = smoother but laggy.",
                        valueText: decimal(settings.emaAlpha),
                        value: $settings.emaAlpha,
                        range: 0.05...1.0,
                        step: 0.05
                    )
                    SettingsSliderRow(
                        title: "Box padding",
                        help: "Extra space around each box. Higher = larger boxes.",
                        valueText: percent(settings.boxInflate),
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
                } header: {
                    Text("Live tracking")
                        .foregroundStyle(BinGuide.cleanInorganic.color)
                } footer: {
                    Text("These only affect the camera overlay.")
                }

                Section {
                    Button("Reset to defaults", role: .destructive) {
                        settings.resetToDefaults()
                    }
                    .font(.system(.body, design: .default))
                }
            }
            .font(.system(.body, design: .default))
            .tint(BinGuide.organic.color)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BinGuide.residual.color.opacity(0.92), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { refreshCameras() }
            .onReceive(
                NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)
            ) { _ in refreshCameras() }
            .onReceive(
                NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)
            ) { _ in
                refreshCameras()
                if settings.preferredCameraID != CameraPreference.autoID,
                   !cameraOptions.contains(where: { $0.id == settings.preferredCameraID })
                {
                    settings.preferredCameraID = CameraPreference.autoID
                }
            }
        }
    }

    private func refreshCameras() {
        // Warm discovery so connect/disconnect notifications keep firing.
        _ = CameraDeviceCatalog.availableOptions()
        cameraOptions = CameraDeviceCatalog.availableOptions()
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private struct SettingsSliderRow: View {
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
            Slider(value: $value, in: range, step: step)
            Text(help)
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsIntSliderRow: View {
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

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
        .environmentObject(RecordingController.shared)
}
