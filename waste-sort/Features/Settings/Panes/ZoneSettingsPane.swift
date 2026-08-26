import SwiftUI

struct ZoneSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var aprilTagStore: AprilTagBindingStore
    @EnvironmentObject private var markerStore: BinMarkerStore
    @EnvironmentObject private var binStyle: BinStyleStore
    @State private var showZoneResetConfirm = false

    var onClose: () -> Void

    var body: some View {
        Form {
            zonesSection
            // Bin openness belongs beside zones because a zone is what a marker is credited
            // to. Only one detector gates deposits at a time, so the one that is not chosen
            // is hidden rather than left on screen looking as though it were doing something.
            MarkerSettingsSections()
            if markerStore.source == .aprilTag {
                aprilTagSection
            }
        }
        .font(.system(.body, design: .default))
    }

    @ViewBuilder
    private var zonesSection: some View {
        Section {
            Toggle("Show zones", isOn: $settings.showZoneOverlay)
            zoneTimingRows
            Button("Edit zones on camera") {
                zoneStore.isEditingZones = true
                onClose()
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
    private var zoneTimingRows: some View {
        SettingsIntSliderRow(
            title: "Dwell frames",
            help: """
                How many frames the model must actually see an item inside a zone before it can be counted. \
                Frames where the box is frozen after a lost detection do not count. \
                Higher = fewer accidental counts when something passes over a bin.
                """,
            value: Binding(
                get: { zoneStore.dwellFrames },
                set: { zoneStore.dwellFrames = $0 }
            ),
            range: ZoneConfig.dwellRange
        )
        SettingsSliderRow(
            title: "Reacquire window",
            help: """
                How long an item that vanishes is given to reappear before it is judged. The model blinks and relabels constantly; \
                anything that comes back inside this window is the same item continuing, not a throw. \
                Also the delay between a real throw and it showing up in History.
                """,
            valueText: String(format: "%.1fs", zoneStore.reacquireGrace),
            value: Binding(
                get: { zoneStore.reacquireGrace },
                set: { zoneStore.reacquireGrace = $0 }
            ),
            range: ZoneConfig.reacquireGraceRange,
            step: 0.1
        )
        SettingsSliderRow(
            title: "Throw feedback delay",
            help: "How soon the category bar and sound react after a throw, and after an item is held in the wrong zone. History still waits for the reacquire window.",
            valueText: String(format: "%.1fs", zoneStore.throwFeedbackGrace),
            value: Binding(
                get: { zoneStore.throwFeedbackGrace },
                set: { zoneStore.throwFeedbackGrace = $0 }
            ),
            range: ZoneConfig.throwFeedbackGraceRange,
            step: 0.1
        )
    }

    @ViewBuilder
    private var aprilTagSection: some View {
        Section {
            Toggle("Enable AprilTag detection", isOn: $aprilTagStore.isEnabled)
            if aprilTagStore.isEnabled {
                aprilTagEnabledControls
            }
        } header: {
            Text("AprilTag Openness")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text(aprilTagFooter)
        }
    }

    @ViewBuilder
    private var aprilTagEnabledControls: some View {
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
        ForEach(zoneStore.zones) { zone in
            AprilTagBindingRow(zone: zone)
        }
    }

    private var aprilTagFooter: String {
        """
        Uses camera to detect when bins are physically opened via inside-mounted tag16h5 AprilTags. \
        Detection range sets capture resolution and how hard the detector works per frame - raise it if tags near the bins go unseen, \
        lower it if the frame rate drops. Closed delay is how long a tag can stay missing before the bin is marked closed.
        """
    }
}

private struct AprilTagBindingRow: View {
    let zone: DropZone
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var aprilTagStore: AprilTagBindingStore
    @EnvironmentObject private var binStyle: BinStyleStore

    var body: some View {
        HStack {
            let bin = binStyle.resolved(zone.bin)
            Image(systemName: bin.symbolName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(bin.color, in: Circle())

            Text(bin.displayName)
            Spacer()
            Picker("Tags", selection: tagIDsBinding) {
                Section("3-Tag Groups") {
                    ForEach(0..<max(4, zoneStore.zones.count + 1), id: \.self) { group in
                        let start = group * 3
                        Text("Group \(group + 1) (#\(start)–#\(start + 2))")
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

    private var tagIDsBinding: Binding<[Int]> {
        Binding(
            get: {
                let index = zoneStore.zones.firstIndex(where: { $0.id == zone.id }) ?? 0
                return aprilTagStore.tagIDs(for: zone.id, defaultIndex: index)
            },
            set: { aprilTagStore.setTagIDs($0, for: zone.id) }
        )
    }
}
