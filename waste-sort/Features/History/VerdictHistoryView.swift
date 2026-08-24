import SwiftUI

/// Everything the on-device model has been asked this session, and what it said.
///
/// Built like `HistoryView` because it answers the neighbouring question — that one records
/// what was thrown away, this one records what the model made of it — but it is session-only
/// by design: the deposit history is the durable record, and a second durable log that
/// disagreed with it would be worse than none.
struct VerdictHistoryView: View {
    @EnvironmentObject private var verdictLog: FoundationVerdictLog
    @Environment(\.dismiss) private var dismiss

    private var records: [FoundationVerdictRecord] { verdictLog.records }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            summary
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }

                        Section("Answers") {
                            ForEach(records) { record in
                                VerdictRow(record: record)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Model verdicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BinGuide.residual.color.opacity(0.92), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        verdictLog.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(records.isEmpty)
                }
            }
        }
        .tint(BinGuide.organic.color)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No answers yet", systemImage: "sparkle.magnifyingglass")
        } description: {
            Text(
                "Each item the detector settles on is cropped and shown to the on-device "
                    + "model. Answers land here — including the ones that were not acted on."
            )
        }
    }

    private var summary: some View {
        let locked = records.filter { $0.lockedBinID != nil }
        let disagreed = locked.filter(\.disagreesWithDetector)
        let failed = records.filter { if case .failed = $0.outcome { return true } else { return false } }
        let latencies = records.map(\.latency).sorted()

        return HStack(spacing: 0) {
            tile("\(locked.count)/\(records.count)", "confirmed", BinGuide.organic.color)
            divider
            tile("\(disagreed.count)", "≠ detector", .orange)
            divider
            tile(failed.isEmpty ? "—" : "\(failed.count)", "failed", failed.isEmpty ? .secondary : .red)
            divider
            tile(medianText(latencies), "median", .secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1, height: 28)
    }

    private func tile(_ value: String, _ caption: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(caption)
                .font(.system(.caption2, design: .default))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func medianText(_ sorted: [TimeInterval]) -> String {
        guard !sorted.isEmpty else { return "—" }
        let middle = sorted[sorted.count / 2]
        return "\(Int((middle * 1000).rounded()))ms"
    }
}

/// One trip to the model: what it was shown, what it answered, and how that compared with
/// the detector.
private struct VerdictRow: View {
    let record: FoundationVerdictRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                    Text(headline)
                        .font(.system(.subheadline, design: .default).weight(.semibold))
                }
                .foregroundStyle(tint)

                if !record.label.isEmpty {
                    Text("“\(record.label)”")
                        .font(.system(.footnote, design: .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text("detector: \(BinGuide.info(for: record.detectorClassKey).title)")
                        .foregroundStyle(record.disagreesWithDetector ? .orange : .secondary)
                    if record.confidence > 0 {
                        Text("· \(Int((record.confidence * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(.caption, design: .default))

                Text(
                    "#\(record.trackID) · \(Int((record.latency * 1000).rounded()))ms · "
                        + record.timestamp.formatted(date: .omitted, time: .standard)
                )
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Group {
            if let image = record.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color(.tertiarySystemFill))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(tint.opacity(0.5), lineWidth: 1.5)
        }
    }

    private var headline: String {
        switch record.outcome {
        case .locked(let binID):
            return BinGuide.bin(id: binID).displayName
        case .declined(let reason):
            return reason.prefix(1).uppercased() + reason.dropFirst()
        case .failed:
            return "Model error"
        }
    }

    private var symbol: String {
        switch record.outcome {
        case .locked(let binID):
            return BinGuide.bin(id: binID).symbolName
        case .declined:
            return "questionmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch record.outcome {
        case .locked(let binID):
            return BinGuide.bin(id: binID).color
        case .declined:
            return .yellow
        case .failed:
            return .red
        }
    }
}
