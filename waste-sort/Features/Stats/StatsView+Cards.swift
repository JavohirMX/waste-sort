import SwiftUI

// MARK: - Generated-waste and bins-filled cards

extension StatsView {
    /// Left column: title + total + legend; right: wide track bars.
    var generatedCard: some View {
        StatsCardSurface {
            if snapshot.isEmpty && !useMockDailyBars {
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
                HStack(alignment: .top, spacing: isWide ? 20 : 14) {
                    generatedSummaryColumn
                        .frame(width: isWide ? 150 : 120, alignment: .leading)

                    categoryBars
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .font(.system(size: isWide ? 48 : 40, weight: .bold, design: .default).monospacedDigit())
                    .foregroundStyle(Color(white: 0.12))
                Text("items")
                    .font(.system(size: isWide ? 20 : 16, weight: .medium, design: .default))
                    .foregroundStyle(Color(white: 0.35))
            }

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

    /// Equal-height gray tracks with bottom-up colored fills and icons (design crop).
    private var categoryBars: some View {
        let peak = displayCategoryCounts.map(\.count).max() ?? 0
        let yMax: Int = {
            if useMockDailyBars { return 150 }
            return max(150, Int((Double(peak) * 1.1 / 50).rounded(.up) * 50))
        }()
        let ticks = stride(from: 0, through: yMax, by: 50).map { $0 }

        return GeometryReader { geo in
            let trackHeight = max(geo.size.height - 4, 160)
            let barWidth: CGFloat = isWide ? 96 : 68
            let yLabelWidth: CGFloat = 28
            let chartWidth = max(geo.size.width - yLabelWidth, 120)

            ZStack(alignment: .bottomLeading) {
                ForEach(ticks, id: \.self) { tick in
                    let y = trackHeight * (1 - CGFloat(tick) / CGFloat(yMax))
                    Path { path in
                        path.move(to: CGPoint(x: yLabelWidth, y: y))
                        path.addLine(to: CGPoint(x: yLabelWidth + chartWidth, y: y))
                    }
                    .stroke(Color.black.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    Text("\(tick)")
                        .font(.system(size: 13, weight: .medium, design: .default).monospacedDigit())
                        .foregroundStyle(Color(white: 0.4))
                        .position(x: 12, y: y)
                }

                HStack(alignment: .bottom, spacing: isWide ? 24 : 16) {
                    ForEach(binStyle.orderedBins) { bin in
                        let count = displayCategoryCounts.first { $0.binID == bin.id }?.count ?? 0
                        let fillRatio = CGFloat(count) / CGFloat(max(yMax, 1))
                        let fillHeight = max(trackHeight * fillRatio, count > 0 ? 44 : 0)

                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color(white: 0.93))
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

    var binsFilledCard: some View {
        StatsCardSurface {
            VStack(alignment: .leading, spacing: isWide ? 18 : 12) {
                Text("Bins filled")
                    .font(.system(size: isWide ? 19 : 17, weight: .semibold, design: .default))
                    .foregroundStyle(.gray)
//                    .underline()

                VStack(spacing: isWide ? 12 : 8) {
                    ForEach(binStyle.orderedBins) { bin in
                        let count = binsFilledCounts.first { $0.binID == bin.id }?.count ?? 0
                        HStack(spacing: 14) {
                            Image(systemName: bin.symbolName)
                                .font(.system(size: isWide ? 22 : 18, weight: .bold))
                                .foregroundStyle(bin.color)

                            Text(bin.displayName.capitalized)
                                .font(.system(size: isWide ? 18 : 15, weight: .medium, design: .default))
                                .foregroundStyle(Color(white: 0.40))

                            Spacer()

                            Text("\(count)")
                                .font(.system(size: isWide ? 22 : 18, weight: .bold, design: .default).monospacedDigit())
                                .foregroundStyle(Color(white: 0.12))
                        }
                        .padding(.horizontal, isWide ? 20 : 14)
                        .padding(.vertical, isWide ? 14 : 10)
                        .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
