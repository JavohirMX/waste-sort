import SwiftUI

/// Bottom-left confirmation of the most recent item dropped into a zone.
///
/// Doubles as the entry point to the full history — the thing you glance at is the
/// thing you tap when you want the rest.
struct LastDepositChip: View {
    let record: ZoneEventRecord
    var isFresh: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            chipContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Last item: \(record.bin.displayName) into \(record.zoneName), "
                + (record.isCorrect ? "correct" : "wrong bin")
        )
        .accessibilityHint("Opens history")
    }

    private var chipContent: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(record.bin.color)
                    .frame(width: 34, height: 34)
                Image(systemName: record.bin.symbolName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: record.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(record.isCorrect ? BinGuide.organic.color : .red, .white)
                    .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(record.bin.displayName)
                    .font(.system(.footnote, design: .default).weight(.bold))
                    .foregroundStyle(.white)
                relativeTimeLine
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    (record.isCorrect ? BinGuide.organic.color : Color.red)
                        .opacity(isFresh ? 0.95 : 0),
                    lineWidth: 2
                )
        }
        .scaleEffect(isFresh ? 1.06 : 1)
    }

    /// Re-renders every 30 s so the relative-time label stays current; without
    /// this the text froze at whatever moment the last unrelated render happened.
    private var relativeTimeLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let elapsed = context.date.timeIntervalSince(record.timestamp)
            let relative = elapsed < 60 ? "just now" : record.timestamp.formatted(.relative(presentation: .numeric))
            return Text("\(record.zoneName) · \(relative)")
                .font(.system(.caption2, design: .default))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }
}
