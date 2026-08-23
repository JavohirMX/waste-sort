import SwiftUI

struct CategorySegmentFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Top category bar. Segments light up when that bin is present in frame.
struct CategoryBar: View {
    var bins: [BinInfo] = BinGuide.all
    let counts: [String: Int]
    var ctaStyle: CTAStyle = .off
    var onTripleTap: (() -> Void)? = nil
    @Environment(\.hudTextScale) private var hudTextScale

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(bins.enumerated()), id: \.element.id) { index, bin in
                let detected = CategoryPresence.isDetected(binID: bin.id, counts: counts)
                CategorySegment(
                    bin: bin,
                    isDetected: detected,
                    isPulsing: ctaStyle == .pulseLabel && detected,
                    cornerIndex: index,
                    cornerCount: bins.count,
                    textScale: hudTextScale
                )
                .overlay(alignment: .trailing) {
                    if index < bins.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 1)
                    }
                }
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: CategorySegmentFramesKey.self,
                            value: [bin.id: geo.frame(in: .named(CTASpace.name))]
                        )
                    }
                }
                .onTapGesture(count: 3) {
                    onTripleTap?()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.barHeight)
        .background {
            Color.clear
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: Theme.barCornerRadius, style: .continuous)
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if onTripleTap != nil {
                Button("Open developer settings") {
                    onTripleTap?()
                }
            }
        }
    }

    private var accessibilityLabel: String {
        bins.map { bin in
            let state = CategoryPresence.isDetected(binID: bin.id, counts: counts) ? "detected" : "not detected"
            return "\(bin.displayName) \(state)"
        }
        .joined(separator: ", ")
    }
}

private struct CategorySegment: View {
    let bin: BinInfo
    let isDetected: Bool
    let isPulsing: Bool
    let cornerIndex: Int
    let cornerCount: Int
    var textScale: CGFloat = 1

    var body: some View {
        HStack(spacing: 8 * textScale) {
            Image(systemName: bin.symbolName)
                .font(.system(size: 16 * textScale, weight: .semibold))
            Text(bin.displayName)
                .font(.system(size: 14 * textScale, weight: .semibold))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(isDetected ? 1.0 : 0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background((isDetected ? bin.color : bin.idleColor).opacity(
            isDetected ? Theme.segmentDetectedOpacity : Theme.segmentIdleOpacity
        ))
        .clipShape(segmentShape)
        .compositingGroup()
        .modifier(CTAPulseModifier(isActive: isPulsing))
        .zIndex(isPulsing ? 1 : 0)
        .animation(.easeInOut(duration: Theme.animationDuration), value: isDetected)
    }

    private var segmentShape: UnevenRoundedRectangle {
        let radius = Theme.barCornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: cornerIndex == 0 ? radius : 0,
            bottomLeadingRadius: cornerIndex == 0 ? radius : 0,
            bottomTrailingRadius: cornerIndex == cornerCount - 1 ? radius : 0,
            topTrailingRadius: cornerIndex == cornerCount - 1 ? radius : 0,
            style: .continuous
        )
    }
}

private struct CTAPulseModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { context in
            content.scaleEffect(pulseScale(at: context.date))
        }
    }

    private func pulseScale(at date: Date) -> CGFloat {
        guard isActive else { return 1 }
        let turns = date.timeIntervalSinceReferenceDate / Theme.ctaPulsePeriod
        let wave = 0.5 + 0.5 * sin(turns * 2 * .pi)
        return 1.0 + (Theme.ctaPulseScale - 1.0) * wave
    }
}

#Preview {
    ZStack {
        Color.gray
        CategoryBar(counts: ["residual": 2, "clean_inorganic": 1], ctaStyle: .pulseLabel)
            .padding()
    }
}
