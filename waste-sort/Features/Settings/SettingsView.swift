import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recording: RecordingController
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var history: ZoneEventHistoryStore
    @EnvironmentObject private var aprilTagStore: AprilTagBindingStore
    @Environment(\.dismiss) private var dismiss
    @State private var cameraOptions: [CameraOption] = CameraDeviceCatalog.availableOptions()
    @State private var showPhotoSort = false
    @State private var showHistory = false
    @State private var showZoneResetConfirm = false
    /// Sampled when the sheet opens: the model can finish downloading between visits.
    @State private var confirmationAvailability = FoundationCategoryAvailability.current

    var body: some View {
        NavigationStack {
            Form {
                recordingSection
                cameraSection
                captureSection
                zonesSection
                aprilTagSection
                historySection
                photoSection
                liveOverlaySection
                confirmationSection
                modelSection
                detectionSection
                liveTrackingSection

                Section {
                    Button("Reset to defaults", role: .destructive) {
                        settings.resetToDefaults()
                    }
                    .font(.system(.body, design: .default))
                }
            }
            .font(.system(.body, design: .default))
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                refreshCameras()
                confirmationAvailability = .current
            }
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
    private var recordingSection: some View {
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

            Toggle("Auto-record on open", isOn: $settings.autoRecordOnOpen)

            if let status = recording.statusMessage {
                Text(status)
                    .font(.system(.footnote, design: .default))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Recording")
                .foregroundStyle(Color.red.opacity(0.85))
        } footer: {
            Text(recordingFooter)
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
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
    }

    @ViewBuilder
    private var captureSection: some View {
        Section {
            SettingsPickerRow(
                title: "Exposure",
                help: "Lock auto-exposure so a bright item does not pump the picture. USB webcams may ignore this.",
                isLocked: $settings.exposureLocked
            )
            SettingsPickerRow(
                title: "Focus",
                help: "Lock focus so the lens does not hunt while items pass. USB webcams may ignore this.",
                isLocked: $settings.focusLocked
            )
            SettingsPickerRow(
                title: "White balance",
                help: "Lock white balance so colors stay stable. USB webcams may ignore this.",
                isLocked: $settings.whiteBalanceLocked
            )
            SettingsSliderRow(
                title: "Brightness",
                help: "Brighten or darken the image the model sees.",
                valueText: signedDecimal(settings.brightness),
                value: $settings.brightness,
                range: FrameColorAdjuster.brightnessRange,
                step: 0.05
            )
            SettingsSliderRow(
                title: "Contrast",
                help: "Increase or decrease contrast before detection.",
                valueText: decimal(settings.contrast),
                value: $settings.contrast,
                range: FrameColorAdjuster.contrastRange,
                step: 0.05
            )
            SettingsSliderRow(
                title: "Saturation",
                help: "Increase or decrease color intensity before detection.",
                valueText: decimal(settings.saturation),
                value: $settings.saturation,
                range: FrameColorAdjuster.saturationRange,
                step: 0.05
            )
            Button("Reset capture") {
                settings.resetCaptureToDefaults()
            }
            .disabled(settings.isCaptureAtDefaults)
        } header: {
            Text("Capture")
                .foregroundStyle(BinGuide.residual.color)
        } footer: {
            Text("These adjust the image the model sees. USB cameras ignore hardware lock more often than these sliders.")
        }
    }

    @ViewBuilder
    private var zonesSection: some View {
        Section {
            Toggle("Show zones", isOn: $settings.showZoneOverlay)

            SettingsIntSliderRow(
                title: "Dwell frames",
                help: "How many frames the model must actually see an item inside a zone before it can be counted. Frames where the box is frozen after a lost detection do not count. Higher = fewer accidental counts when something passes over a bin.",
                value: Binding(
                    get: { zoneStore.dwellFrames },
                    set: { zoneStore.dwellFrames = $0 }
                ),
                range: ZoneConfig.dwellRange
            )

            SettingsSliderRow(
                title: "Reacquire window",
                help: "How long an item that vanishes is given to reappear before it is judged. The model blinks and relabels constantly; anything that comes back inside this window is the same item continuing, not a throw. Also the delay between a real throw and it showing up in History.",
                valueText: String(format: "%.1fs", zoneStore.reacquireGrace),
                value: Binding(
                    get: { zoneStore.reacquireGrace },
                    set: { zoneStore.reacquireGrace = $0 }
                ),
                range: ZoneConfig.reacquireGraceRange,
                step: 0.1
            )

            Button("Edit zones on camera") {
                zoneStore.isEditingZones = true
                dismiss()
            }
            .disabled(zoneStore.zones.isEmpty)

            Button("Reset zones", role: .destructive) { showZoneResetConfirm = true }
        } header: {
            Text("Zones")
                .foregroundStyle(BinGuide.cleanInorganic.color)
        }
        .confirmationDialog(
            "Reset zones to defaults?",
            isPresented: $showZoneResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset zones", role: .destructive) {
                zoneStore.resetToDefaults(
                    rotation: settings.liveRotation,
                    mirror: settings.liveMirror
                )
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var aprilTagSection: some View {
        Section {
            Toggle("Enable AprilTag detection", isOn: $aprilTagStore.isEnabled)

            if aprilTagStore.isEnabled {
                Toggle("Show debug overlay", isOn: $aprilTagStore.showDebugOverlay)

                Picker("Detection range", selection: $aprilTagStore.rangeProfile) {
                    ForEach(AprilTagRangeProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.segmented)

                Text(aprilTagStore.rangeProfile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SettingsSliderRow(
                    title: "Closed delay",
                    help: "How long a tag can be missing before the bin is marked closed. Lower = lids register closed sooner; higher = more tolerant of brief dropouts.",
                    valueText: String(format: "%.1fs", aprilTagStore.staleTimeout),
                    value: $aprilTagStore.staleTimeout,
                    range: AprilTagConfig.staleTimeoutRange,
                    step: AprilTagConfig.staleTimeoutStep
                )

                if !zoneStore.zones.isEmpty {
                    ForEach(zoneStore.zones) { zone in
                        HStack {
                            Image(systemName: zone.bin.symbolName)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(zone.bin.color, in: Circle())

                            Text(zone.name)
                            Spacer()
                            Picker("Tags", selection: Binding(
                                get: {
                                    let index = zoneStore.zones.firstIndex(where: { $0.id == zone.id }) ?? 0
                                    return aprilTagStore.tagIDs(for: zone.id, defaultIndex: index)
                                },
                                set: { aprilTagStore.setTagIDs($0, for: zone.id) }
                            )) {
                                Section("3-Tag Groups") {
                                    ForEach(0..<max(4, zoneStore.zones.count + 1), id: \.self) { g in
                                        let start = g * 3
                                        Text("Group \(g + 1) (#\(start)–#\(start + 2))")
                                            .tag([start, start + 1, start + 2])
                                    }
                                }
                                Section("Single Tags") {
                                    ForEach(0..<max(12, (zoneStore.zones.count + 1) * 3), id: \.self) { tagID in
                                        Text("Single Tag #\(tagID)").tag([tagID])
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
        } header: {
            Text("AprilTag Openness")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text("Uses camera to detect when bins are physically opened via inside-mounted tag16h5 AprilTags. Detection range sets capture resolution and how hard the detector works per frame - raise it if tags near the bins go unseen, lower it if the frame rate drops. Closed delay is how long a tag can stay missing before the bin is marked closed.")
        }
    }

    @ViewBuilder
    private var historySection: some View {
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
    }

    @ViewBuilder
    private var photoSection: some View {
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
    }

    @ViewBuilder
    private var liveOverlaySection: some View {
        Section {
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
        } header: {
            Text("Live overlay")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text("Shown on the live camera when waste is detected. Choose one visual guide at a time. Box badges can show an icon, category name, and confidence percent; placement moves the badge around each box.")
        }
    }

    @ViewBuilder
    private var confirmationSection: some View {
        Section {
            Toggle("Confirm with on-device model", isOn: $settings.foundationConfirmationEnabled)

            LabeledContent("Status") {
                Text(confirmationAvailability.isReady ? "Ready" : "Off")
                    .foregroundStyle(confirmationAvailability.isReady ? .green : .secondary)
            }

            Toggle("Show verdict log on Live", isOn: $settings.foundationVerdictLogEnabled)
                .disabled(!settings.foundationConfirmationEnabled)
        } header: {
            Text("Category confirmation")
                .foregroundStyle(BinGuide.cleanInorganic.color)
        } footer: {
            Text(
                "The detector keeps finding items as it does now. On top of that, each item is "
                    + "photographed and shown to the on-device Foundation model, and whatever it "
                    + "answers is locked in — the category stops changing for as long as that item "
                    + "stays on screen. Its box breathes while the model is thinking and flashes "
                    + "when the answer lands.\n\n\(confirmationAvailability.summary)"
            )
        }
    }

    @ViewBuilder
    private var modelSection: some View {
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
    }

    @ViewBuilder
    private var detectionSection: some View {
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
    }

    @ViewBuilder
    private var liveTrackingSection: some View {
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
                title: "Class-change overlap",
                help: "How much a relabelled box must overlap to stay the same item. Cannot be tighter than Same-item overlap.",
                valueText: decimal(settings.crossClassIou),
                value: $settings.crossClassIou,
                range: 0.1...0.9,
                step: 0.05
            )
            SettingsSliderRow(
                title: "Label stickiness",
                help: "How long a new bin must lead (by confidence) before the label changes. Higher = less flicker, slower to correct.",
                valueText: String(format: "%.2f s", settings.classLockWindow),
                value: $settings.classLockWindow,
                range: 0.10...1.00,
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
            Text("These only affect the camera overlay. Throw scoring still uses a lifetime vote of the raw model class.")
        }
    }

    private var recordingFooter: String {
        guard recording.hasLiveSession else {
            return "The live camera must be running before you can start a recording."
        }
        let saves =
            "Saves a raw clip to Photos, an overlay clip (boxes, labels, timestamps) to Photos and Files, and a detection CSV to Files (On My iPad/iPhone → Sortla). Records the camera feed only for the raw clip. Saves if you stop, or if the app is backgrounded or closed."
        if settings.autoRecordOnOpen {
            return "Starts automatically when the app opens or returns to the foreground. \(saves)"
        }
        return saves
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

    private func signedDecimal(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }
}

private struct SettingsPickerRow: View {
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
        .environmentObject(ZoneStore.shared)
        .environmentObject(ZoneEventHistoryStore.shared)
        .environmentObject(AprilTagBindingStore.shared)
}
