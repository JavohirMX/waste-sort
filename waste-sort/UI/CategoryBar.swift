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
                    scale: hudTextScale
                )
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: CategorySegmentFramesKey.self,
                            value: [bin.id: geo.frame(in: .named(CTASpace.name))]
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: (Theme.barTrayHeight - Theme.barGlassInset * 2) * hudTextScale)
        // The rim is what makes the tray read as glass: the segments are translucent, so
        // without an inset there is nothing left of the material to see.
        .padding(Theme.barGlassInset * hudTextScale)
        .background {
            RoundedRectangle(
                cornerRadius: Theme.barCornerRadius * hudTextScale,
                style: .continuous
            )
            .fill(Color.black.opacity(0.10))
        }
        .glassEffect(
            .regular,
            in: RoundedRectangle(
                cornerRadius: Theme.barCornerRadius * hudTextScale,
                style: .continuous
            )
        )
        .padding(Theme.barPageInset * hudTextScale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
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
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: Theme.barIconGap * scale) {
            Image(systemName: bin.symbolName)
                .font(BrandFont.body(Theme.barFontSize * scale, weight: .bold))
            Text(bin.displayName)
                .font(BrandFont.body(Theme.barFontSize * scale, weight: .bold))
                .tracking(Theme.barTracking * scale)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        .padding(.horizontal, Theme.barSegmentHPadding * scale)
        .padding(.vertical, Theme.barSegmentVPadding * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fill)
        .clipShape(segmentShape)
        .compositingGroup()
        .modifier(CTAPulseModifier(isActive: isPulsing))
        .zIndex(isPulsing ? 1 : 0)
        .animation(.easeInOut(duration: Theme.animationDuration), value: isDetected)
    }

    /// The bin's drawn gradient, brightest along the bottom edge. Only the alpha changes
    /// with detection, so an idle segment stays a wash the glass shows through.
    private var fill: LinearGradient {
        let gradient = bin.barGradient
        let alpha = isDetected ? Theme.segmentDetectedOpacity : gradient.idleAlpha
        return LinearGradient(
            colors: [gradient.top.opacity(alpha), gradient.bottom.opacity(alpha)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var segmentShape: UnevenRoundedRectangle {
        let radius = Theme.barSegmentRadius * scale
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
        LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        CategoryBar(counts: ["residual": 2, "clean_inorganic": 1], ctaStyle: .pulseLabel)
            .padding()
    }
    .ignoresSafeArea()
}
