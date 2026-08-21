import SwiftUI

/// Debug read-out of what the on-device model has been answering, newest at the top.
///
/// Sits under the live picture as a console rather than a designed HUD element, because
/// that is what it is: the answer to "why is nothing being confirmed", which the boxes
/// alone cannot give — a declined answer and a wedged model look identical on screen.
struct FoundationVerdictStrip: View {
    let records: [FoundationVerdictRecord]
    var limit = 5
    var onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header

            if records.isEmpty {
                Text("waiting for the first answer…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(records.prefix(limit)) { record in
                    row(for: record)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 10, weight: .bold))
            Text("MODEL VERDICTS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
            Spacer(minLength: 8)
            if !records.isEmpty {
                Button("clear", action: onClear)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    @ViewBuilder
    private func row(for record: FoundationVerdictRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            thumbnail(for: record)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: symbol(for: record))
                        .font(.system(size: 10, weight: .bold))
                    Text(verdictText(for: record))
                        .lineLimit(1)
                }
                .foregroundStyle(tint(for: record))

                HStack(spacing: 6) {
                    Text(time(record.timestamp))
                    Text("#\(record.trackID)")
                    // Only worth the space when the two disagree — that is the row you are
                    // looking for when you scan this thing.
                    if record.disagreesWithDetector {
                        Text("detector said \(BinGuide.info(for: record.detectorClassKey).title)")
                            .foregroundStyle(.orange.opacity(0.9))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Text("\(Int((record.latency * 1000).rounded()))ms")
                }
                .foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    @ViewBuilder
    private func thumbnail(for record: FoundationVerdictRecord) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Group {
            if let thumbnail = record.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(.white.opacity(0.08))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(tint(for: record).opacity(0.7), lineWidth: 1.5)
        }
    }

    private func verdictText(for record: FoundationVerdictRecord) -> String {
        switch record.outcome {
        case .locked(let binID):
            let name = BinGuide.bin(id: binID).title
            let detail = record.label.isEmpty ? name : "\(name) · \(record.label)"
            return "\(detail) \(percent(record.confidence))"
        case .declined(let reason):
            let seen = record.label.isEmpty ? "" : "\(record.label) "
            return "declined — \(seen)\(reason) \(percent(record.confidence))"
        case .failed(let message):
            return "failed — \(message)"
        }
    }

    private func symbol(for record: FoundationVerdictRecord) -> String {
        switch record.outcome {
        case .locked(let binID):
            return BinGuide.bin(id: binID).symbolName
        case .declined:
            return "questionmark.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for record: FoundationVerdictRecord) -> Color {
        switch record.outcome {
        case .locked(let binID):
            return BinGuide.bin(id: binID).color
        case .declined:
            return .white.opacity(0.75)
        case .failed:
            return .red.opacity(0.9)
        }
    }

    private func percent(_ value: Double) -> String {
        value > 0 ? "\(Int((value * 100).rounded()))%" : ""
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
