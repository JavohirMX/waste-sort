import Charts
import SwiftUI
import UIKit

struct StatsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var history: ZoneEventHistoryStore
    @EnvironmentObject var binStyle: BinStyleStore
    @EnvironmentObject private var zoneStore: ZoneStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State var period: StatsPeriod = .daily
    @State private var showBinSettings = false
    @State private var showSiteNameEditor = false
    @State private var siteNameDraft = ""

    /// Used when Stats is shown as an overlay (slide from right) instead of a cover.
    var onClose: (() -> Void)?

    var events: [ZoneEventRecord] {
        settings.useMockStats ? StatsMockData.events() : history.events
    }

    var snapshot: StatsSnapshot {
        StatsAggregator.snapshot(
            events: events,
            period: period,
            binIDs: binStyle.orderedBins.map(\.id)
        )
    }

    var timelineBuckets: [StatsTimeBucket] {
        if settings.useMockStats, period == .daily {
            return StatsMockData.dailyTimelineBuckets()
        }
        return snapshot.timeBuckets
    }

    /// Daily mock uses design overlay heights; otherwise live category counts.
    var displayCategoryCounts: [StatsCategoryCount] {
        if settings.useMockStats, period == .daily {
            return binStyle.orderedBins.map { bin in
                StatsCategoryCount(
                    binID: bin.id,
                    count: StatsMockData.categoryCounts[bin.id] ?? 0
                )
            }
        }
        return snapshot.categoryCounts
    }

    var binsFilledCounts: [StatsCategoryCount] {
        if settings.useMockStats {
            return binStyle.orderedBins.map { bin in
                StatsCategoryCount(
                    binID: bin.id,
                    count: StatsMockData.binsFilled[bin.id] ?? 0
                )
            }
        }
        return snapshot.destinationCounts
    }

    var isWide: Bool { horizontalSizeClass == .regular }

    var useMockDailyBars: Bool { settings.useMockStats && period == .daily }

    var body: some View {
        ZStack {
            CameraGlassBackdrop()

            NavigationStack {
                ZStack {
                    ClearHostingBackground()
                    GeometryReader { geo in
                        let bottomReserve: CGFloat = 76
                        let contentHeight = max(geo.size.height - bottomReserve, 400)

                        VStack(alignment: .leading, spacing: isWide ? 22 : 16) {
                            headerRow

                            periodPicker

                            if isWide && geo.size.width > 700 {
                                landscapeBody(contentHeight: contentHeight)
                            } else {
                                ScrollView {
                                    VStack(spacing: 18) {
                                        generatedCard
                                            .frame(minHeight: 320)
                                        binsFilledCard
                                            .frame(minHeight: 300)
                                        timelineCard
                                            .frame(height: 360)
                                    }
                                    .padding(.bottom, 24)
                                }
                            }
                        }
                        .padding(.horizontal, GlassChrome.pageInset)
                        .padding(.top, 12)
                        .padding(.bottom, bottomReserve)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    }

                    VStack {
                        Spacer()
                        HStack {
                            dismissGlassButton
                            Spacer()
                        }
                        .padding(.bottom, Theme.hudInset)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
                .overlay(alignment: .topTrailing) {
                    GlassChrome.glassCircleButton(
                        systemName: "gearshape.fill",
                        accessibilityLabel: "Bin Settings"
                    ) {
                        showBinSettings = true
                    }
                    .padding(.top, 16)
                    .padding(.trailing, GlassChrome.pageInset)
                }
                .navigationDestination(isPresented: $showBinSettings) {
                    BinSettingsView()
                        .environmentObject(binStyle)
                        .environmentObject(zoneStore)
                        .environmentObject(settings)
                }
                .sheet(isPresented: $showSiteNameEditor) {
                    SiteNameEditorSheet(
                        siteNameDraft: $siteNameDraft,
                        onCancel: { showSiteNameEditor = false },
                        onSave: {
                            let trimmed = siteNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                binStyle.siteName = trimmed
                            }
                            showSiteNameEditor = false
                        }
                    )
                    .presentationDetents([.height(260)])
                    .presentationDragIndicator(.visible)
                }
                .onAppear { configureSegmentedPickerAppearance() }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .containerBackground(.clear, for: .navigation)
            .background(.clear)
            .background { ClearHostingBackground() }
        }
        .background(.clear)
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    private func configureSegmentedPickerAppearance() {
        let control = UISegmentedControl.appearance()
        control.selectedSegmentTintColor = .white
        control.backgroundColor = UIColor(white: 0.88, alpha: 1)
        control.setTitleTextAttributes(
            [
                .foregroundColor: UIColor(white: 0.28, alpha: 1),
                .font: UIFont.systemFont(ofSize: 16, weight: .medium)
            ],
            for: .normal
        )
        control.setTitleTextAttributes(
            [
                .foregroundColor: UIColor(white: 0.12, alpha: 1),
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold)
            ],
            for: .selected
        )
    }

    private func landscapeBody(contentHeight: CGFloat) -> some View {
        let headerBlock: CGFloat = 120
        let gap: CGFloat = 22
        let usable = max(contentHeight - headerBlock, 360)
        let topHeight = usable * 0.46
        let bottomHeight = usable * 0.50

        return VStack(spacing: gap) {
            HStack(alignment: .top, spacing: 20) {
                generatedCard
                binsFilledCard
            }
            .frame(height: topHeight)

            timelineCard
                .frame(height: bottomHeight)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var headerRow: some View {
        Button {
            siteNameDraft = binStyle.siteName
            showSiteNameEditor = true
        } label: {
            Text("Waste Stats | \(binStyle.siteName)")
                .font(.system(size: isWide ? 38 : 28, weight: .bold, design: .default))
                .foregroundStyle(Color(white: 0.12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 60)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Waste Stats, \(binStyle.siteName)")
        .accessibilityHint("Double tap to edit site name")
    }

    private var dismissGlassButton: some View {
        Button {
            closeStats()
        } label: {
            GlassChrome.edgeTabLabel(edge: .leading) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.3.trianglepath")
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to camera")
    }

    private func closeStats() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

#Preview {
    StatsView()
        .environmentObject(AppSettings.shared)
        .environmentObject(ZoneEventHistoryStore.shared)
        .environmentObject(BinStyleStore.shared)
        .environmentObject(ZoneStore.shared)
}
