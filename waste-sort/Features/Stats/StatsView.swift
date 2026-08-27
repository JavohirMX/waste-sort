import Charts
import SwiftUI
import UIKit

struct StatsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: ZoneEventHistoryStore
    @EnvironmentObject private var binStyle: BinStyleStore
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var binPreview: BinPreviewCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var period: StatsPeriod = .daily
    @State private var showBinSettings = false
    @State private var showSiteNameEditor = false
    @State private var siteNameDraft = ""

    /// Used when Stats is shown as an overlay (slide from right) instead of a cover.
    var onClose: (() -> Void)?

    private var snapshot: StatsSnapshot {
        let binIDs = binStyle.orderedBins.map(\.id)
        if settings.useMockStats {
            return StatsMockData.snapshot(period: period, binIDs: binIDs)
        }
        return StatsAggregator.snapshot(
            events: history.events,
            period: period,
            binIDs: binIDs
        )
    }

    private var timelineBuckets: [StatsTimeBucket] {
        snapshot.timeBuckets
    }

    private var isWide: Bool { horizontalSizeClass == .regular }

    private var generatedTotalPointSize: CGFloat {
        switch String(snapshot.generatedTotal).count {
        case 0...3:
            return isWide ? 48 : 40
        case 4:
            return isWide ? 34 : 28
        default:
            return isWide ? 26 : 22
        }
    }

    var body: some View {
        ZStack {
            Theme.statsSettingsBackground.ignoresSafeArea()

            NavigationStack {
                ZStack {
                    ClearHostingBackground()
                    GeometryReader { geo in
                        let bottomReserve: CGFloat = 76

                        VStack(alignment: .leading, spacing: isWide ? 22 : 16) {
                            headerRow

                            periodPicker

                            if StatsLayout.usesSplitLayout(size: geo.size, isRegularWidth: isWide) {
                                landscapeBody
                            } else {
                                ScrollView {
                                    VStack(spacing: 18) {
                                        generatedCard
                                            .frame(minHeight: 320)
                                        thrownIntoCard()
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
                        .environmentObject(binPreview)
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
                .onAppear {
                    configureSegmentedPickerAppearance()
                    if binPreview.returnsToBinSettings {
                        binPreview.returnsToBinSettings = false
                        showBinSettings = true
                    }
                }
                .onChange(of: binPreview.isActive) { _, isActive in
                    if isActive { closeStats() }
                }
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
        // Leaving the tint/background alone lets the system render its native Liquid Glass
        // material for the control instead of a flat custom fill.
        let control = UISegmentedControl.appearance()
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

    private var landscapeBody: some View {
        GeometryReader { inner in
            let metrics = StatsLayout.splitBodyMetrics(size: inner.size)
            VStack(spacing: metrics.gap) {
                HStack(alignment: .top, spacing: metrics.columnGap) {
                    generatedCard
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .clipped()
                    thrownIntoCard(compact: metrics.usesCompactChrome)
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .clipped()
                }
                .frame(height: metrics.topHeight)
                timelineCard
                    .frame(height: metrics.bottomHeight)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private var generatedCard: some View {
        StatsCardSurface {
            if snapshot.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Generated waste")
                        .font(.system(size: isWide ? 19 : 17, weight: .medium, design: .default))
                        .foregroundStyle(.secondary)
                    Text("No waste recorded yet")
                        .font(.system(size: 16, weight: .regular, design: .default))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                GeometryReader { card in
                    HStack(alignment: .top, spacing: isWide ? 20 : 14) {
                        generatedSummaryColumn
                            .frame(
                                width: StatsLayout.generatedSummaryWidth(
                                    isWide: isWide,
                                    cardInnerWidth: card.size.width
                                ),
                                alignment: .leading
                            )
                        categoryBars
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var generatedSummaryColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generated waste")
                .font(.system(size: isWide ? 18 : 16, weight: .medium, design: .default))
                .foregroundStyle(Color(white: 0.45))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(snapshot.generatedTotal)")
                    .font(.system(size: generatedTotalPointSize, weight: .bold, design: .default).monospacedDigit())
                    .foregroundStyle(Color(white: 0.12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                Text("items")
                    .font(.system(size: isWide ? 20 : 16, weight: .medium, design: .default))
                    .foregroundStyle(Color(white: 0.35))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Spacer()
                ForEach(binStyle.orderedBins) { bin in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(bin.color)
                            .frame(width: 11, height: 11)
                        Text(bin.displayName.capitalized)
                            .font(.system(size: isWide ? 16 : 14, weight: .medium, design: .default))
                            .foregroundStyle(Color(white: 0.4))
                    }
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
    }

    /// Equal-height gray tracks with bottom-up colored fills and icons.
    private var categoryBars: some View {
        let peak = snapshot.categoryCounts.map(\.count).max() ?? 0
        let axis = StatsChartScale.axis(peak: peak)
        let yMax = axis.max
        let yLabelWidth: CGFloat = axis.max >= 1_000 ? 36 : 28
        return GeometryReader { geo in
            let trackHeight = max(geo.size.height - 4, 0)
            let chartWidth = max(geo.size.width - yLabelWidth, 0)
            let barWidth = StatsLayout.barWidth(
                availableWidth: chartWidth, binCount: binStyle.orderedBins.count, isWide: isWide
            )
            ZStack(alignment: .bottomLeading) {
                ForEach(axis.ticks, id: \.self) { tick in
                    let y = trackHeight * (1 - CGFloat(tick) / CGFloat(yMax))
                    Path { path in
                        path.move(to: CGPoint(x: yLabelWidth, y: y))
                        path.addLine(to: CGPoint(x: yLabelWidth + chartWidth, y: y))
                    }
                    .stroke(Color.black.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Text(StatsChartScale.label(tick))
                        .font(.system(size: 13, weight: .medium, design: .default).monospacedDigit())
                        .foregroundStyle(Color(white: 0.4))
                        .position(x: yLabelWidth / 2, y: y)
                }
                HStack(alignment: .bottom, spacing: StatsLayout.barSpacing(isWide: isWide)) {
                    ForEach(binStyle.orderedBins) { bin in
                        let count = snapshot.categoryCounts.first { $0.binID == bin.id }?.count ?? 0
                        let fillRatio = CGFloat(count) / CGFloat(max(yMax, 1))
                        let fillHeight = max(trackHeight * fillRatio, count > 0 ? 44 : 0)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color.white)
                                .frame(width: barWidth, height: trackHeight)
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(bin.color)
                                .frame(width: barWidth, height: fillHeight)
                                .overlay(alignment: .bottom) {
                                    if count > 0 {
                                        Image(systemName: bin.symbolName)
                                            .font(.system(size: isWide ? 24 : 20, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.bottom, 16)
                                    }
                                }
                        }
                        .frame(width: barWidth, height: trackHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.leading, yLabelWidth)
            }
            .frame(width: geo.size.width, height: trackHeight)
        }
    }

    private func thrownIntoCard(compact: Bool = false) -> some View {
        let metrics = StatsLayout.thrownIntoMetrics(isWide: isWide, compact: compact)
        return StatsCardSurface(padding: metrics.cardPadding) {
            VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                Text("Thrown into")
                    .font(.system(size: metrics.titleSize, weight: .semibold, design: .default))
                    .foregroundStyle(.gray)
                VStack(spacing: metrics.rowSpacing) {
                    ForEach(binStyle.orderedBins) { bin in
                        let placement = snapshot.placements.first { $0.binID == bin.id }
                            ?? StatsBinPlacement(binID: bin.id, total: 0, correct: 0)
                        ThrownIntoRow(bin: bin, placement: placement, metrics: metrics)
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
    }

    private var timelineCard: some View {
        let peak = timelineBuckets.map { max($0.generated, $0.misplaced) }.max() ?? 0
        let axis = StatsChartScale.axis(peak: peak)
        let chartYMax = axis.max
        let chartYTicks = axis.ticks
        let trailingInset: CGFloat = isWide ? 160 : 130

        return StatsCardSurface(padding: 22) {
            HStack(alignment: .top, spacing: 0) {
                Chart {
                    ForEach(timelineBuckets) { bucket in
                        LineMark(
                            x: .value("Time", bucket.date),
                            y: .value("Items", bucket.generated),
                            series: .value("Series", "Generated")
                        )
                        .foregroundStyle(Color(red: 0.0, green: 0.48, blue: 1.0))
                        .lineStyle(StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)

                        LineMark(
                            x: .value("Time", bucket.date),
                            y: .value("Items", bucket.misplaced),
                            series: .value("Series", "Misplaced")
                        )
                        .foregroundStyle(Color(red: 0.95, green: 0.22, blue: 0.25))
                        .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round, dash: [10, 6]))
                        .interpolationMethod(.linear)
                    }
                }
                .chartYScale(domain: 0...chartYMax)
                .chartXAxis {
                    AxisMarks(values: timelineXTicks) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(xAxisLabel(date))
                                    .font(.system(size: 14, weight: .medium, design: .default))
                                    .foregroundStyle(Color(white: 0.4))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: chartYTicks) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(Color.black.opacity(0.14))
                        AxisValueLabel {
                            if let n = value.as(Int.self) {
                                Text(StatsChartScale.label(n))
                                    .font(.system(size: 13, weight: .medium, design: .default).monospacedDigit())
                                    .foregroundStyle(Color(white: 0.4))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .modifier(DailyXDomainModifier(domain: timelineXDomain))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .trailing, spacing: 0) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Correct Bin")
                            .font(.system(size: isWide ? 20 : 16, weight: .medium, design: .default))
                            .foregroundStyle(Color(white: 0.12))
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(snapshot.correctlyPlacedPercent)")
                                .font(.system(size: isWide ? 48 : 36, weight: .bold, design: .default).monospacedDigit())
                                .foregroundStyle(Color(white: 0.12))
                            Text("%")
                                .font(.system(size: isWide ? 48 : 36, weight: .bold, design: .default))
                                .foregroundStyle(Color(white: 0.12))
                        }
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 10) {
                        legendRow(
                            color: Color(red: 0.0, green: 0.48, blue: 1.0),
                            label: "Correct bin",
                            dashed: false
                        )
                        legendRow(
                            color: Color(red: 0.95, green: 0.22, blue: 0.25),
                            label: "Misplaced waste",
                            dashed: true
                        )
                    }
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .padding(.bottom, 8)
                }
                .frame(width: trailingInset, alignment: .trailing)
                .padding(.leading, 8)
            }
        }
    }

    /// Fixed 7am–7pm domain for Daily so 7 pm is always visible.
    private var timelineXDomain: ClosedRange<Date>? {
        guard period == .daily else { return nil }
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        guard let start = cal.date(byAdding: .hour, value: 7, to: startOfDay),
              let end = cal.date(byAdding: .hour, value: 19, to: startOfDay)
        else { return nil }
        return start...end
    }

    private var timelineXTicks: [Date] {
        switch period {
        case .daily:
            let cal = Calendar.current
            let startOfDay = cal.startOfDay(for: Date())
            return [7, 10, 13, 16, 19].compactMap { hour in
                cal.date(byAdding: .hour, value: hour, to: startOfDay)
            }
        case .weekly, .monthly, .yearly:
            let buckets = timelineBuckets.map(\.date)
            guard buckets.count > 1 else { return buckets }
            let step = max(1, buckets.count / 5)
            return stride(from: 0, to: buckets.count, by: step).map { buckets[$0] }
        }
    }

    private func xAxisLabel(_ date: Date) -> String {
        switch period {
        case .daily:
            let hour = Calendar.current.component(.hour, from: date)
            let suffix = hour < 12 ? "am" : "pm"
            let h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
            return "\(h12) \(suffix)"
        case .weekly, .monthly:
            return date.formatted(.dateTime.weekday(.abbreviated).day())
        case .yearly:
            return date.formatted(.dateTime.month(.abbreviated))
        }
    }

    private func legendRow(color: Color, label: String, dashed: Bool) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(dashed ? Color.clear : color)
                .frame(width: 28, height: dashed ? 3 : 4)
                .overlay {
                    if dashed {
                        Capsule()
                            .stroke(color, style: StrokeStyle(lineWidth: 3, dash: [6, 4.65]))
                    }
                }
            Text(label)
                .foregroundStyle(Color(white: 0.4))
        }
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

private struct DailyXDomainModifier: ViewModifier {
    let domain: ClosedRange<Date>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartXScale(domain: domain)
        } else {
            content
        }
    }
}

private struct SiteNameEditorSheet: View {
    @Binding var siteNameDraft: String
    var onCancel: () -> Void
    var onSave: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shown in the Waste Stats title.")
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)

                TextField("Site name", text: $siteNameDraft)
                    .font(.system(size: 20, weight: .regular, design: .default))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($fieldFocused)

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Site name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { fieldFocused = true }
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
