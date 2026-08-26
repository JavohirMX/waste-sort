import SwiftUI

/// The bin-openness half of Settings: which detector gates deposits, and how the marker
/// strips are set up when that is the one chosen.
///
/// Split out of `SettingsView` rather than added to it — that file is already past the length
/// warning, and a settings screen is exactly the kind of file that rots by accretion.
struct MarkerSettingsSections: View {
    @EnvironmentObject private var markerStore: BinMarkerStore
    /// Only for the capture-resolution picker, which lives in that store for historical
    /// reasons and is not an AprilTag setting at all — both detectors read the same frames.
    @EnvironmentObject private var aprilTagStore: AprilTagBindingStore

    var body: some View {
        sourceSection
        if markerStore.source == .marker {
            markerSection
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            Picker("Detected by", selection: $markerStore.source) {
                ForEach(BinOpennessSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Bin Openness")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text(sourceFooter)
        }
    }

    private var sourceFooter: String {
        switch markerStore.source {
        case .aprilTag:
            return "Bins read as open while a tag mounted inside them is visible."
        case .marker:
            return "Bins read as open while a printed strip mounted inside them is visible. "
                + "Only one detector gates deposits at a time, so switching here switches what "
                + "the camera is actually looking for."
        }
    }

    @ViewBuilder
    private var markerSection: some View {
        Section {
            Picker("Printed on the strip", selection: $markerStore.kind) {
                ForEach(BinMarkerKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Text("\(markerStore.kind.detail) Cut it from \(markerStore.kind.sheetPage).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if markerStore.kind.hasHeightChoice {
                Picker("Row height", selection: $markerStore.dashProfile) {
                    ForEach(BinMarkerDashProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.segmented)

                Text(markerStore.dashProfile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Show debug overlay", isOn: $markerStore.showDebugOverlay)

            Picker("Capture resolution", selection: $aprilTagStore.rangeProfile) {
                ForEach(AprilTagRangeProfile.allCases) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .pickerStyle(.segmented)

            Text(captureDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingsSliderRow(
                title: "Closed delay",
                help: "How long a strip can be missing before the bin is marked closed. "
                    + "Lower notices a real lid sooner; higher forgives an arm reaching in.",
                valueText: String(format: "%.1fs", markerStore.staleTimeout),
                value: $markerStore.staleTimeout,
                range: BinMarkerStateConfig.staleTimeoutRange,
                step: BinMarkerStateConfig.staleTimeoutStep
            )

            if markerStore.isCalibrated {
                Button("Clear color calibration", role: .destructive) {
                    markerStore.clearCalibration()
                }
                .font(.system(.body, design: .default))
            }
        } header: {
            Text("Marker Strips")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text(markerFooter)
        }
    }

    /// The dash kinds read the full luma frame; bars meet chroma at half the capture width.
    /// Either way the sampler caps the working grid at 1920 across, so 4K costs frame rate to
    /// produce samples that are thrown away again.
    private var captureDetail: String {
        let full = markerStore.kind.style.usesDashRows
        switch aprilTagStore.rangeProfile {
        case .near:
            return full
                ? "720p — 1280 samples across. Halves the working grid; print larger."
                : "720p — 640 samples across. Bars have to be printed larger still."
        case .far:
            return full
                ? "1080p — 1920 samples across. The right setting."
                : "1080p — 960 samples across. The right setting for bars."
        case .veryFar:
            return "4K — capped back to 1920 samples, so it buys range only for AprilTags."
        }
    }

    /// No per-bin setup, and that is worth saying out loud on the screen where it used to be:
    /// a row of pickers binding each bin to its own strip was the first thing anyone opening
    /// this screen had to get right, and it is gone.
    private var markerFooter: String {
        "All three bins carry the same strip — a marker is credited to whichever bin it "
            + "appears nearest, because the camera and the bins do not move. Mount it level "
            + "and inside, on the rim a shut drawer hides under the counter."
    }
}
