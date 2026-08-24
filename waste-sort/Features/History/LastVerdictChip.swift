import SwiftUI

/// The most recent answer from the on-device model, sitting beside the last-deposit chip.
///
/// Deliberately the same shape and weight as `LastDepositChip`: the two read as a pair —
/// what was thrown away, and what the model made of it — and the thing you glance at is the
/// thing you tap when you want the rest.
struct LastVerdictChip: View {
    let record: FoundationVerdictRecord
    var isFresh: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                thumbnail

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(.footnote, design: .default).weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(isFresh ? 0.95 : 0), lineWidth: 2)
            }
            .scaleEffect(isFresh ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model said \(headline)")
        .accessibilityHint("Opens the model's verdict log")
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Group {
            if let image = record.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(.white.opacity(0.1))
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(tint)
                    }
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(tint.opacity(0.85), lineWidth: 1.5)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: badgeSymbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint, .white)
                .offset(x: 4, y: 4)
        }
    }

    private var headline: String {
        switch record.outcome {
        case .locked(let binID):
            return BinGuide.bin(id: binID).displayName
        case .declined:
            return "NO ANSWER"
        case .failed:
            return "FAILED"
        }
    }

    private var subtitle: String {
        let when = relativeTime
        switch record.outcome {
        case .locked:
            let name = record.label.isEmpty ? "confirmed" : record.label
            return "\(name) · \(when)"
        case .declined(let reason):
            return "\(reason) · \(when)"
        case .failed:
            return "model error · \(when)"
        }
    }

    private var symbol: String {
        switch record.outcome {
        case .locked(let binID):
            return BinGuide.bin(id: binID).symbolName
        case .declined:
            return "questionmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var badgeSymbol: String {
        switch record.outcome {
        case .locked:
            return record.disagreesWithDetector ? "arrow.triangle.2.circlepath.circle.fill" : "sparkles"
        case .declined:
            return "questionmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
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

    private var relativeTime: String {
        let elapsed = Date().timeIntervalSince(record.timestamp)
        if elapsed < 60 { return "just now" }
        return record.timestamp.formatted(.relative(presentation: .numeric))
    }
}
