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
    @EnvironmentObject private var settings: AppSettings

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
            .disabled(settings.demoMode)
        } header: {
            Text("Bin Openness")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text(sourceFooter)
        }
    }

    private var sourceFooter: String {
        if settings.demoMode {
            return "Demo mode leaves bins open. Turn it off to use lid detection."
        }
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

            if markerStore.kind.style.usesDashRows {
                SettingsIntSliderRow(
                    title: "Dashes to open",
                    help: "How much of the printed row has to clear the counter edge before "
                        + "the bin reads open. This is the drawer travel: at an 8 mm dash, "
                        + "each one is another 16 mm of pull.",
                    value: $markerStore.dashesToOpen,
                    range: BinMarkerDashConfig.dashesToOpenRange
                )

                Text(dashesDetail)
                    .font(.caption)
                    .foregroundStyle(dashesBelowFloor ? .orange : .secondary)
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
        .disabled(settings.demoMode)
    }

    /// Below the floor this height and shape were measured at, the room starts producing rows
    /// on its own, and it climbs steeply: over fifteen site frames, a handful at one dash
    /// under and hundreds not far below that.
    private var dashesBelowFloor: Bool {
        markerStore.dashesToOpen < markerStore.measuredDashesToOpen
    }

    /// Says what the measurement said, and where the current setting stands against it, rather
    /// than clamping the slider. Below the floor is a thing worth trying on the actual bins;
    /// it is just not a thing to walk into without being told.
    private var dashesDetail: String {
        let floor = markerStore.measuredDashesToOpen
        if markerStore.dashesToOpen < floor {
            return "Below the \(floor) this height was measured clean at, and it climbs "
                + "steeply: a handful of stray rows over fifteen site frames at one dash "
                + "under, hundreds not far below that. Watch the debug overlay before "
                + "leaving it here."
        }
        if markerStore.dashesToOpen == floor {
            return "The floor this height was measured clean at on this site's own frames."
        }
        return "\(markerStore.dashesToOpen - floor) more than this height needs. Slower to "
            + "open, and further from anything the room can counterfeit."
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
        if settings.demoMode {
            return "Demo mode leaves bins open. Turn it off to use lid detection."
        }
        return "All three bins carry the same strip — a marker is credited to whichever bin it "
            + "appears nearest, because the camera and the bins do not move. Mount it level "
            + "and inside, on the rim a shut drawer hides under the counter."
    }
}
