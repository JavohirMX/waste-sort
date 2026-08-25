import AVFoundation
import SwiftUI

struct SettingsView: View {
    /// Used when Settings is shown as an overlay (slide from right) instead of a cover.
    var onClose: (() -> Void)?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedPane: SettingsPane = .recording
    @State private var query = ""
    @State private var cameraOptions: [CameraOption] = CameraDeviceCatalog.availableOptions()

    private var isWide: Bool { horizontalSizeClass == .regular }
    private var searchHits: [SettingsSearchHit] { SettingsSearch.matches(query) }
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isWide {
                wideSplit
            } else {
                compactStack
            }
        }
        .background(.background)
        .onAppear { refreshCameras() }
        .onReceive(
            NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)
        ) { _ in refreshCameras() }
        .onReceive(
            NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)
        ) { _ in
            refreshCameras()
            if settings.preferredCameraID != CameraPreference.autoID,
               !cameraOptions.contains(where: { $0.id == settings.preferredCameraID }) {
                settings.preferredCameraID = CameraPreference.autoID
            }
        }
    }

    private var wideSplit: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            NavigationStack {
                paneView(selectedPane)
                    .id(selectedPane)
                    .navigationTitle(selectedPane.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
    }

    private var compactStack: some View {
        NavigationStack {
            sidebar
                .navigationDestination(for: SettingsPane.self) { pane in
                    paneView(pane)
                        .navigationTitle(pane.title)
                }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search"
        )
    }

    private var sidebar: some View {
        List {
            if isSearching {
                searchSection
            } else {
                paneSections
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
        .toolbar { doneButton }
    }

    @ViewBuilder
    private var paneSections: some View {
        ForEach(SettingsPane.sidebarGroups) { group in
            Section(group.title) {
                ForEach(group.panes, id: \.self) { pane in
                    paneRow(pane)
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if searchHits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ForEach(searchHits) { hit in
                searchRow(hit)
            }
        }
    }

    @ViewBuilder
    private func paneRow(_ pane: SettingsPane) -> some View {
        let label = SettingsSidebarLabel(
            title: pane.title,
            systemImage: pane.systemImage,
            iconColor: pane.iconColor
        )
        if isWide {
            Button {
                selectedPane = pane
            } label: {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selectionBackground(isSelected: selectedPane == pane))
        } else {
            NavigationLink(value: pane) { label }
        }
    }

    @ViewBuilder
    private func searchRow(_ hit: SettingsSearchHit) -> some View {
        let label = SettingsSidebarLabel(
            title: hit.title,
            systemImage: hit.pane.systemImage,
            iconColor: hit.pane.iconColor,
            subtitle: hit.pane.title
        )
        if isWide {
            Button {
                selectedPane = hit.pane
            } label: {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selectionBackground(isSelected: selectedPane == hit.pane))
        } else {
            NavigationLink(value: hit.pane) { label }
        }
    }

    private func selectionBackground(isSelected: Bool) -> Color {
        isSelected ? Color.primary.opacity(0.08) : Color.clear
    }

    @ToolbarContentBuilder
    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { close() }
        }
    }

    @ViewBuilder
    private func paneView(_ pane: SettingsPane) -> some View {
        switch pane {
        case .recording:
            RecordingSettingsPane()
        case .camera:
            CameraSettingsPane(cameraOptions: $cameraOptions)
        case .zones:
            ZoneSettingsPane(onClose: close)
        case .overlay:
            OverlaySettingsPane()
        case .detection:
            DetectionSettingsPane()
        case .tracking:
            TrackingSettingsPane()
        case .tools:
            ToolsSettingsPane(onClose: close)
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func refreshCameras() {
        // Warm discovery so connect/disconnect notifications keep firing.
        _ = CameraDeviceCatalog.availableOptions()
        cameraOptions = CameraDeviceCatalog.availableOptions()
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
        .environmentObject(RecordingController.shared)
        .environmentObject(ZoneStore.shared)
        .environmentObject(ZoneEventHistoryStore.shared)
        .environmentObject(AprilTagBindingStore.shared)
        .environmentObject(BinStyleStore.shared)
}
