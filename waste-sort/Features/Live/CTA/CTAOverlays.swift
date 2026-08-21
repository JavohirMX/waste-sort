import SwiftUI

struct CTADropdownOverlay: View {
    let activeBinIDs: Set<String>
    let segmentFrames: [String: CGRect]
    @EnvironmentObject private var binStyle: BinStyleStore

    var body: some View {
        ZStack {
            ForEach(binStyle.orderedBins) { bin in
                if let frame = segmentFrames[bin.id] {
                    dropdownCard(for: bin)
                        .frame(width: max(frame.width - 12, 160), height: 72, alignment: .top)
                        .position(x: frame.midX, y: frame.maxY + 36)
                        .opacity(activeBinIDs.contains(bin.id) ? 1 : 0)
                        .offset(y: activeBinIDs.contains(bin.id) ? 0 : -8)
                        .animation(.easeInOut(duration: Theme.animationDuration), value: activeBinIDs)
                        .accessibilityHidden(!activeBinIDs.contains(bin.id))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func dropdownCard(for bin: BinInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.bin.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(bin.color)
            Text(Theme.ctaDropdownMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.18))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bin.displayName). \(Theme.ctaDropdownMessage)")
    }
}

struct CTAHighlightOverlay: View {
    let activeBinIDs: Set<String>
    let viewSize: CGSize
    let barBottom: CGFloat
    @EnvironmentObject private var binStyle: BinStyleStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: activeBinIDs.isEmpty)) { context in
            let opacity = highlightOpacity(at: context.date)
            let bins = binStyle.orderedBins
            let columnWidth = viewSize.width / CGFloat(max(bins.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(bins.enumerated()), id: \.element.id) { index, bin in
                    if activeBinIDs.contains(bin.id) {
                        Rectangle()
                            .fill(bin.color.opacity(opacity))
                            .frame(width: columnWidth, height: max(viewSize.height - barBottom, 0))
                            .offset(x: CGFloat(index) * columnWidth, y: barBottom)
                    }
                }
            }
            .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
            .animation(.easeInOut(duration: Theme.animationDuration), value: activeBinIDs)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func highlightOpacity(at date: Date) -> Double {
        guard !activeBinIDs.isEmpty else { return Theme.ctaHighlightOpacity }
        let turns = date.timeIntervalSinceReferenceDate / Theme.ctaHighlightPulsePeriod
        let wave = 0.5 + 0.5 * sin(turns * 2 * .pi)
        return Theme.ctaHighlightOpacity + Theme.ctaHighlightPulseAmount * wave
    }
}

struct CTAArrowOverlay: View {
    let cues: [CTACue]
    let segmentFrames: [String: CGRect]
    @EnvironmentObject private var binStyle: BinStyleStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: cues.isEmpty)) { context in
            let phase = CTAArrowPath.wrap01(
                CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2)
            )
            ZStack {
                ForEach(cues) { cue in
                    arrowChevrons(for: cue, phase: phase)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func arrowChevrons(for cue: CTACue, phase: CGFloat) -> some View {
        if let frame = segmentFrames[cue.binID] {
            let start = CGPoint(x: cue.displayRect.midX, y: cue.displayRect.minY)
            let end = CGPoint(x: frame.midX, y: frame.maxY)
            let samples = CTAArrowPath.samples(from: start, to: end, phase: phase)
            let bin = binStyle.resolved(BinGuide.bin(id: cue.binID))
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Image(systemName: "chevron.up")
                    .font(.system(size: sample.size, weight: .heavy))
                    .foregroundStyle(bin.color.opacity(sample.opacity))
                    .rotationEffect(.radians(sample.angle))
                    .position(sample.point)
            }
        }
    }
}

nonisolated enum CTALayout {
    static func convert(_ rect: CGRect, from origin: CGPoint) -> CGRect {
        CGRect(
            x: rect.minX - origin.x,
            y: rect.minY - origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    static func barBottom(from segmentFrames: [String: CGRect], fallback: CGFloat) -> CGFloat {
        segmentFrames.values.map(\.maxY).max() ?? fallback
    }
}
