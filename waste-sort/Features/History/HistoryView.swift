import SwiftUI

/// Persistent log of items dropped into calibrated zones.
struct HistoryView: View {
    @EnvironmentObject private var history: ZoneEventHistoryStore
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var binStyle: BinStyleStore
    @State private var showClearConfirm = false
    @State private var exportURL: URL?

    private var events: [ZoneEventRecord] { history.events }

    var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            HistorySummaryView(events: events)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }

                        ForEach(groupedDays, id: \.day) { group in
                            Section(dayTitle(group.day)) {
                                ForEach(group.events) { event in
                                    HistoryRow(event: event)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BinGuide.residual.color.opacity(0.92), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            exportURL = history.exportCSV()
                        } label: {
                            Label("Export CSV to Files", systemImage: "square.and.arrow.down")
                        }
                        .disabled(events.isEmpty)

                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("Clear history", systemImage: "trash")
                        }
                        .disabled(events.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog(
                "Delete all \(events.count) recorded items?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear history", role: .destructive) { history.clear() }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Exported",
                isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })
            ) {
                Button("OK") { exportURL = nil }
            } message: {
                Text("Saved \(exportURL?.lastPathComponent ?? "") to On My iPad → Sortla.")
            }
        }
        .tint(BinGuide.organic.color)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No items yet", systemImage: "tray")
        } description: {
            Text(
                zoneStore.zones.isEmpty
                    ? "Add drop zones in Settings → Zones, then items released into a zone appear here."
                    : "Items are recorded when they are released inside a drop zone on the Live tab."
            )
        }
    }

    private var groupedDays: [(day: Date, events: [ZoneEventRecord])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: events) { calendar.startOfDay(for: $0.timestamp) }
        return buckets
            .map { (day: $0.key, events: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct HistoryRow: View {
    let event: ZoneEventRecord
    @EnvironmentObject private var binStyle: BinStyleStore

    private var bin: BinInfo { binStyle.resolved(event.bin) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(event.isCorrect ? BinGuide.organic.color : Color.red)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: bin.symbolName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(bin.color, in: Circle())

                    Text(bin.displayName)
                        .font(.system(.subheadline, design: .default).weight(.semibold))

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)

                    Text(event.zoneName)
                        .font(.system(.subheadline, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(.caption, design: .default).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text("\(Int((event.confidence * 100).rounded()))%")
                .font(.system(.caption, design: .default).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

#Preview {
    HistoryView()
        .environmentObject(ZoneEventHistoryStore.shared)
        .environmentObject(ZoneStore.shared)
        .environmentObject(BinStyleStore.shared)
}
