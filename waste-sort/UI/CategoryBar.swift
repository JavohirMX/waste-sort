import SwiftUI

/// Top 3-segment category bar. Segments light up when that bin is present in frame.
struct CategoryBar: View {
    let counts: [String: Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(BinGuide.all.enumerated()), id: \.element.id) { index, bin in
                let detected = CategoryPresence.isDetected(binID: bin.id, counts: counts)
                CategorySegment(bin: bin, isDetected: detected)
                    .overlay(alignment: .trailing) {
                        if index < BinGuide.all.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 1)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.barHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            Color.clear
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        BinGuide.all.map { bin in
            let state = CategoryPresence.isDetected(binID: bin.id, counts: counts) ? "detected" : "not detected"
            return "\(bin.displayName) \(state)"
        }
        .joined(separator: ", ")
    }
}

private struct CategorySegment: View {
    let bin: BinInfo
    let isDetected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bin.symbolName)
                .font(.system(size: 16, weight: .semibold))
            Text(bin.displayName)
                .font(Theme.categoryLabelFont)
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white.opacity(isDetected ? 1.0 : 0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            (isDetected ? bin.color : bin.idleColor)
                .opacity(isDetected ? Theme.segmentDetectedOpacity : Theme.segmentIdleOpacity)
        )
        .animation(.easeInOut(duration: Theme.animationDuration), value: isDetected)
    }
}

#Preview {
    ZStack {
        Color.gray
        CategoryBar(counts: ["residual": 2, "clean_inorganic": 1])
            .padding()
    }
}
