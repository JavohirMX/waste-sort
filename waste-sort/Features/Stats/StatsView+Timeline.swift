import Charts
import SwiftUI

// MARK: - Timeline chart card

extension StatsView {
    var timelineCard: some View {
        let chartYMax = (settings.useMockStats && period == .daily) ? 200 : timelineYAxisMax
        let chartYTicks = stride(from: 0, through: chartYMax, by: 50).map { $0 }
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
                                Text("\(n)")
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

    private var timelineYAxisMax: Int {
        let peak = timelineBuckets.map { max($0.generated, $0.misplaced) }.max() ?? 0
        if peak <= 0 { return 50 }
        let stepped = Int((Double(peak) * 1.15 / 50).rounded(.up) * 50)
        return max(stepped, 50)
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
}
