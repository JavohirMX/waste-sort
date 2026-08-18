import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var history: ZoneEventHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var cameraOptions: [CameraOption] = CameraDeviceCatalog.availableOptions()
    @State private var showPhotoSort = false
    @State private var showHistory = false
    @State private var showZoneResetConfirm = false

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

                    Picker("Rotation", selection: $settings.liveRotation) {
                        ForEach(LivePreviewRotation.allCases) { rotation in
                            Text(rotation.displayName).tag(rotation)
                        }
                    }

                    Toggle("Mirror", isOn: $settings.liveMirror)
                } header: {
                    Text("Camera")
                        .foregroundStyle(BinGuide.residual.color)
                } footer: {
                    Text("Auto uses a connected USB-C webcam when available, otherwise the iPad back camera. Rotation and mirror apply to Live preview and to recordings started after you change them.")
                }

                zonesSection

                Section {
                    Button("History") { showHistory = true }
                    if !history.events.isEmpty {
                        Text("\(history.events.count) recorded items")
                            .font(.system(.footnote, design: .default))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("History")
                        .foregroundStyle(BinGuide.organic.color)
                } footer: {
                    Text("Everything dropped into a zone, with counters and charts. Recorded whether or not a video recording is running.")
                }

                Section {
                    Button("Sort a photo") {
                        showPhotoSort = true
                    }
                } header: {
                    Text("Photo")
                        .foregroundStyle(BinGuide.cleanInorganic.color)
                } footer: {
                    Text("Pick a still image from your library and sort items without the live camera.")
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
                            ? "Saves a raw clip to Photos, an overlay clip (boxes, labels, timestamps) to Photos and Files, and a detection CSV to Files (On My iPad/iPhone → iSort). Records the camera feed only for the raw clip. Saves if you stop, or if the app is backgrounded or closed."
                            : "The live camera must be running before you can start a recording."
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
                    Toggle("Show confidence", isOn: $settings.showConfidence)
                } header: {
                    Text("Detection")
                        .foregroundStyle(BinGuide.organic.color)
                } footer: {
                    Text("These affect live camera and photo sorting. Confidence labels appear on each box as a percent.")
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
            .sheet(isPresented: $showHistory) {
                HistoryView()
                    .environmentObject(history)
                    .environmentObject(zoneStore)
            }
            .sheet(isPresented: $showPhotoSort) {
                PhotoSortView()
                    .environmentObject(settings)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var zonesSection: some View {
        Section {
            ForEach(zoneStore.zones) { zone in
                ZoneSettingsRow(zone: zone) { zoneStore.update($0) }
            }
            .onDelete { offsets in
                for index in offsets { zoneStore.remove(id: zoneStore.zones[index].id) }
            }

            SettingsIntSliderRow(
                title: "Dwell frames",
                help: "How long an item must sit inside a zone before it can be counted. Higher = fewer accidental counts when something passes over a bin.",
                value: Binding(
                    get: { zoneStore.dwellFrames },
                    set: { zoneStore.dwellFrames = $0 }
                ),
                range: ZoneConfig.dwellRange
            )

            Button("Edit zones on camera") {
                zoneStore.isEditingZones = true
                dismiss()
            }
            .disabled(zoneStore.zones.isEmpty)

            Button("Add zone") { zoneStore.addZone() }

            Button("Reset zones", role: .destructive) { showZoneResetConfirm = true }
        } header: {
            Text("Zones")
                .foregroundStyle(BinGuide.cleanInorganic.color)
        } footer: {
            Text("Draw a zone over each real bin. Zones are hidden on the live feed except while editing. An item is recorded only if it was first seen outside the zones, then stayed inside one for the dwell frames above and disappeared there — carrying it across a bin, or an item the model first spots already inside, does not count.")
        }
        .confirmationDialog(
            "Reset zones to defaults?",
            isPresented: $showZoneResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset zones", role: .destructive) { zoneStore.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
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

private struct ZoneSettingsRow: View {
    let zone: DropZone
    var onChange: (DropZone) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: zone.bin.symbolName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(zone.bin.color, in: Circle())

            TextField(
                "Zone name",
                text: Binding(
                    get: { zone.name },
                    set: { var copy = zone; copy.name = $0; onChange(copy) }
                )
            )

            Picker(
                "",
                selection: Binding(
                    get: { zone.binID },
                    set: { var copy = zone; copy.binID = $0; onChange(copy) }
                )
            ) {
                ForEach(BinGuide.all) { bin in
                    Text(bin.displayName).tag(bin.id)
                }
            }
            .labelsHidden()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
        .environmentObject(RecordingController.shared)
        .environmentObject(ZoneStore.shared)
        .environmentObject(ZoneEventHistoryStore.shared)
}
