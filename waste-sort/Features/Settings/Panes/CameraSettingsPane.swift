import SwiftUI

struct CameraSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var cameraOptions: [CameraOption]

    var body: some View {
        Form {
            cameraSection
            captureSection
        }
        .font(.system(.body, design: .default))
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
                   !cameraOptions.contains(where: { $0.id == newValue }) {
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
            captureLockRows
            captureColorRows
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
    private var captureLockRows: some View {
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
    }

    @ViewBuilder
    private var captureColorRows: some View {
        SettingsSliderRow(
            title: "Brightness",
            help: "Brighten or darken the image the model sees.",
            valueText: SettingsFormat.signedDecimal(settings.brightness),
            value: $settings.brightness,
            range: FrameColorAdjuster.brightnessRange,
            step: 0.05
        )
        SettingsSliderRow(
            title: "Contrast",
            help: "Increase or decrease contrast before detection.",
            valueText: SettingsFormat.decimal(settings.contrast),
            value: $settings.contrast,
            range: FrameColorAdjuster.contrastRange,
            step: 0.05
        )
        SettingsSliderRow(
            title: "Saturation",
            help: "Increase or decrease color intensity before detection.",
            valueText: SettingsFormat.decimal(settings.saturation),
            value: $settings.saturation,
            range: FrameColorAdjuster.saturationRange,
            step: 0.05
        )
    }
}
