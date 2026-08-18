import Charts
import SwiftUI

/// Counters and two small charts over the recorded deposits.
struct HistorySummaryView: View {
    let events: [ZoneEventRecord]

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 days"
        case all = "All"

        var id: String { rawValue }
    }

    @State private var range: Range = .today

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            headline

            if !scoped.isEmpty {
                chartCard("By category") { categoryChart }
                chartCard(range == .today ? "By hour" : "By day") { timeChart }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Data

    private var scoped: [ZoneEventRecord] {
        let calendar = Calendar.current
        switch range {
        case .today:
            return events.filter { calendar.isDateInToday($0.timestamp) }
        case .week:
            guard let cutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))
            else { return events }
            return events.filter { $0.timestamp >= cutoff }
        case .all:
            return events
        }
    }

    private var correctCount: Int { scoped.count { $0.isCorrect } }

    private var accuracy: Int {
        guard !scoped.isEmpty else { return 0 }
        return Int((Double(correctCount) / Double(scoped.count) * 100).rounded())
    }

    private struct CategorySlice: Identifiable {
        let bin: BinInfo
        let correct: Int
        let incorrect: Int
        var id: String { bin.id }
        var total: Int { correct + incorrect }
    }

    private var categorySlices: [CategorySlice] {
        BinGuide.all.map { bin in
            let matching = scoped.filter { $0.bin.id == bin.id }
            return CategorySlice(
                bin: bin,
                correct: matching.count { $0.isCorrect },
                incorrect: matching.count { !$0.isCorrect }
            )
        }
    }

    private struct TimeBucket: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    private var timeBuckets: [TimeBucket] {
        let calendar = Calendar.current
        let component: Calendar.Component = range == .today ? .hour : .day
        let grouped = Dictionary(grouping: scoped) {
            calendar.dateInterval(of: component, for: $0.timestamp)?.start
                ?? calendar.startOfDay(for: $0.timestamp)
        }
        return grouped
            .map { TimeBucket(date: $0.key, count: $0.value.count) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Views

    private var headline: some View {
        HStack(spacing: 12) {
            stat(value: "\(scoped.count)", label: "items", tint: .primary)
            stat(value: "\(accuracy)%", label: "sorted right", tint: accuracyColor)
            stat(value: "\(scoped.count - correctCount)", label: "mismatched", tint: .red)
        }
    }

    private var accuracyColor: Color {
        switch accuracy {
        case 80...: BinGuide.organic.color
        case 50..<80: BinGuide.cleanInorganic.color
        default: .red
        }
    }

    private func stat(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.system(.caption2, design: .default))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chartCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .default).weight(.bold))
                .foregroundStyle(.secondary)
            content()
                .frame(height: 120)
        }
    }

    private var categoryChart: some View {
        Chart(categorySlices) { slice in
            BarMark(
                x: .value("Items", slice.correct),
                y: .value("Category", slice.bin.displayName)
            )
            .foregroundStyle(slice.bin.color)
            .annotation(position: .trailing) {
                Text(slice.total > 0 ? "\(slice.total)" : "")
                    .font(.system(.caption2, design: .default).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            BarMark(
                x: .value("Items", slice.incorrect),
                y: .value("Category", slice.bin.displayName)
            )
            .foregroundStyle(Color.red.opacity(0.75))
        }
        .chartXAxis { AxisMarks(position: .bottom) }
    }

    private var timeChart: some View {
        Chart(timeBuckets) { bucket in
            BarMark(
                x: .value("Time", bucket.date, unit: range == .today ? .hour : .day),
                y: .value("Items", bucket.count)
            )
            .foregroundStyle(BinGuide.organic.color)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel(
                    format: range == .today
                        ? .dateTime.hour()
                        : .dateTime.day().month(.abbreviated)
                )
                if value.as(Date.self) != nil { AxisTick() }
            }
        }
    }
}
