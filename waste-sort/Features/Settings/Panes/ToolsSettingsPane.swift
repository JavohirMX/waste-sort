import SwiftUI

struct ToolsSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: ZoneEventHistoryStore
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var binStyle: BinStyleStore
    @State private var showHistory = false
    @State private var showPhotoSort = false

    var onClose: () -> Void

    var body: some View {
        Form {
            historySection
            photoSection
            Section {
                Button("Show onboarding again") {
                    settings.hasCompletedOnboarding = false
                    onClose()
                }
                .font(.system(.body, design: .default))

                Button("Reset to defaults", role: .destructive) {
                    settings.resetToDefaults()
                }
                .font(.system(.body, design: .default))
            }
        }
        .font(.system(.body, design: .default))
        .navigationDestination(isPresented: $showHistory) {
            HistoryContentView()
                .environmentObject(history)
                .environmentObject(zoneStore)
                .environmentObject(binStyle)
        }
        .navigationDestination(isPresented: $showPhotoSort) {
            PhotoSortView()
                .environmentObject(settings)
                .environmentObject(binStyle)
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
            Toggle("Use mock stats data", isOn: $settings.useMockStats)
        } header: {
            Text("History / Stats")
                .foregroundStyle(BinGuide.organic.color)
        } footer: {
            Text(
                "Everything dropped into a zone, with counters and charts. Recorded whether or not a video recording is running. "
                    + "Mock stats lets you preview the Stats page without real throws and does not change History or recordings."
            )
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
}
