import SwiftUI

/// The bin-openness half of Settings: which detector gates deposits, and how the marker
/// strips are set up when that is the one chosen.
///
/// Split out of `SettingsView` rather than added to it — that file is already past the length
/// warning, and a settings screen is exactly the kind of file that rots by accretion.
struct MarkerSettingsSections: View {
    @EnvironmentObject private var markerStore: BinMarkerStore
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var binStyle: BinStyleStore

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
            Picker("Strip style", selection: $markerStore.style) {
                ForEach(BinMarkerStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Text(markerStore.style.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show debug overlay", isOn: $markerStore.showDebugOverlay)

            SettingsSliderRow(
                title: "Closed delay",
                help: "How long a strip can be missing before the bin is marked closed. "
                    + "Lower notices a real lid sooner; higher forgives an arm reaching in.",
                valueText: String(format: "%.1fs", markerStore.staleTimeout),
                value: $markerStore.staleTimeout,
                range: BinMarkerStateConfig.staleTimeoutRange,
                step: BinMarkerStateConfig.staleTimeoutStep
            )

            ForEach(Array(zoneStore.zones.enumerated()), id: \.element.id) { index, zone in
                bindingRow(zone: zone, defaultIndex: index)
            }

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

    @ViewBuilder
    private func bindingRow(zone: DropZone, defaultIndex: Int) -> some View {
        HStack {
            let bin = binStyle.resolved(zone.bin)
            Image(systemName: bin.symbolName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(bin.color, in: Circle())

            Text(bin.displayName)
            Spacer()
            Picker("Strip", selection: Binding(
                get: { markerStore.slot(for: zone.id, defaultIndex: defaultIndex) },
                set: { markerStore.setSlot($0, for: zone.id) }
            )) {
                ForEach(BinMarkerSlot.all) { slot in
                    Text(slotLabel(slot)).tag(slot.index)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func slotLabel(_ slot: BinMarkerSlot) -> String {
        markerStore.style == .color
            ? "\(slot.displayName) · \(slot.ink.displayName)"
            : "\(slot.displayName) · \(slot.pattern.id) wide"
    }

    private var markerFooter: String {
        let placement = "Each bin carries one printed strip: five bars, one or two units wide, "
            + "with one-unit gaps. Mount it level and inside, where a shut bin hides it."
        guard markerStore.style == .color else { return placement }
        let calibration = markerStore.isCalibrated
            ? " Colors are calibrated to this room."
            : " Colors are uncalibrated — open a bin with the debug overlay on and tap Calibrate."
        return placement + calibration
    }
}
