import SwiftUI

struct DetectionBoxView: View {
    let bin: BinInfo
    var recyclableBin: BinInfo = BinGuide.cleanInorganic
    var isDirtyRecyclable: Bool = false
    let rect: CGRect
    var confidence: Float = 0
    var style: BoxOverlayStyle = .default
    var isCoasting: Bool = false
    /// What the on-device confirmation layer is doing with this item, if anything.
    var confirmation: TrackConfirmation = .idle
    /// True when the belief engine cannot back the label. Dashes the border and adds a
    /// question-mark chip so the kiosk never presents a coin flip as a verdict — even
    /// while the confirmation layer is otherwise idle.
    var isUncertain: Bool = false

    /// Decays from 1 to 0 over `Theme.confirmFlashDuration` the moment a verdict lands.
    @State private var flash: Double = 0

    private var scale: CGFloat { style.badgeScale }
    private var badgeSize: CGFloat { Theme.badgeSize * scale }
    private var capsuleFontSize: CGFloat { 11 * scale }
    private var iconOnlyFontSize: CGFloat { 12 * scale }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: confirmation != .thinking)) { context in
            box.opacity(thinkingOpacity(at: context.date))
        }
        .overlay(alignment: style.placement.alignment) {
            if style.showsBadge {
                categoryBadge
                    .fixedSize()
                    .offset(style.placement.badgeOffset(distance: badgeSize * 0.35))
            }
        }
        .position(x: rect.midX, y: rect.midY)
        .onChange(of: confirmation) { _, updated in
            guard updated == .confirmed else { return }
            flash = 1
            withAnimation(.easeOut(duration: Theme.confirmFlashDuration)) { flash = 0 }
        }
        .accessibilityHidden(true)
    }

    private var box: some View {
        ZStack {
            if isDirtyRecyclable {
                dirtySplitHalf(color: bin.color, residual: true)
                dirtySplitHalf(color: recyclableBin.color, residual: false)
            } else {
                RoundedRectangle(cornerRadius: Theme.boxCornerRadius, style: .continuous)
                    .fill(bin.color.opacity(fillOpacity))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.boxCornerRadius, style: .continuous)
                            .strokeBorder(bin.color, style: strokeStyle)
                    }
                    .overlay {
                        // A second, inset line. Confirmed is the only state that draws it, so the
                        // difference from an ordinary box is one of kind rather than of weight —
                        // a heavier single border reads as "confirmed" long before it is.
                        if confirmation == .confirmed {
                            RoundedRectangle(
                                cornerRadius: Theme.boxCornerRadius - Theme.confirmedInnerInset,
                                style: .continuous
                            )
                            .strokeBorder(bin.color.opacity(0.85), lineWidth: Theme.boxStrokeWidth * 0.6)
                            .padding(Theme.confirmedInnerInset)
                        }
                    }
            }
            confirmFlash
        }
        .frame(width: rect.width, height: rect.height)
        .animation(.easeOut(duration: Theme.animationDuration), value: confirmation)
    }

    /// Residual top-left, recyclable bottom-right — the same diagonal as the suggestion chip.
    private func dirtySplitHalf(color: Color, residual: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.boxCornerRadius, style: .continuous)
        return shape
            .fill(color.opacity(fillOpacity))
            .overlay {
                shape.strokeBorder(color, lineWidth: Theme.confirmedStrokeWidth)
            }
            .mask {
                LinearGradient(
                    stops: residual
                        ? [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.5),
                            .init(color: .clear, location: 0.5),
                        ]
                        : [
                            .init(color: .clear, location: 0.5),
                            .init(color: .white, location: 0.5),
                            .init(color: .white, location: 1),
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }

    /// The flare rides outside the box so it reads as the answer arriving rather
    /// than as the box itself changing size.
    @ViewBuilder
    private var confirmFlash: some View {
        let shape = RoundedRectangle(
            cornerRadius: Theme.boxCornerRadius + Theme.confirmFlashSpread,
            style: .continuous
        )
        Group {
            if isDirtyRecyclable {
                shape.stroke(
                    LinearGradient(
                        colors: [bin.color, recyclableBin.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: Theme.confirmedStrokeWidth
                )
            } else {
                shape.stroke(bin.color, lineWidth: Theme.confirmedStrokeWidth)
            }
        }
        .blur(radius: Theme.confirmFlashSpread * 0.6)
        .padding(-Theme.confirmFlashSpread)
        .opacity(flash)
        .allowsHitTesting(false)
    }

    private var fillOpacity: Double {
        if isCoasting { return Theme.boxFillOpacity * 0.5 }
        if isDirtyRecyclable { return Theme.dirtyRecyclableFillOpacity }
        switch confirmation {
        case .confirmed:
            return Theme.confirmedFillOpacity
        case .thinking, .pending:
            return Theme.boxFillOpacity * 0.6
        case .idle:
            return Theme.boxFillOpacity
        }
    }

    /// Solid means settled. Anything the confirmation layer still intends to act on is
    /// dashed, so a box waiting its turn can never be read as one the model has answered.
    private var strokeStyle: StrokeStyle {
        switch confirmation {
        case .confirmed:
            return StrokeStyle(lineWidth: Theme.confirmedStrokeWidth)
        case .thinking, .pending:
            return StrokeStyle(lineWidth: Theme.boxStrokeWidth, dash: Theme.confirmThinkingDash)
        case .idle:
            // No confirmation intent, but the belief engine can still be unsure.
            return StrokeStyle(lineWidth: Theme.boxStrokeWidth, dash: isUncertain ? [6, 4] : [])
        }
    }

    /// Same sine-wave breathing the CTA overlays use, so the two never fight visually.
    private func thinkingOpacity(at date: Date) -> Double {
        guard confirmation == .thinking else { return 1 }
        let turns = date.timeIntervalSinceReferenceDate / Theme.confirmThinkingPulsePeriod
        let wave = 0.5 + 0.5 * sin(turns * 2 * .pi)
        return Theme.confirmThinkingOpacity + Theme.confirmThinkingPulseAmount * wave
    }

    /// Small question mark appended to the badge for unsure items.
    private var uncertaintyDot: some View {
        Image(systemName: "questionmark.circle.fill")
            .font(.system(size: capsuleFontSize, weight: .bold))
            .foregroundStyle(.white)
            .symbolRenderingMode(.hierarchical)
    }

    private var percentText: String {
        "\(Int((Double(confidence) * 100).rounded()))%"
    }

    @ViewBuilder
    private var categoryBadge: some View {
        if isDirtyRecyclable {
            dirtyRecyclableBadge
        } else if style.isIconOnly {
            ZStack {
                Circle()
                    .fill(bin.color)
                    .frame(width: badgeSize, height: badgeSize)
                Image(systemName: bin.symbolName)
                    .font(.system(size: iconOnlyFontSize, weight: .bold))
                    .foregroundStyle(.white)
                if isUncertain {
                    uncertaintyDot
                }
            }
        } else {
            HStack(spacing: 4 * scale) {
                if style.showIcon {
                    Image(systemName: bin.symbolName)
                        .font(.system(size: capsuleFontSize, weight: .bold))
                }
                if style.showCategory {
                    Text(bin.displayName)
                        .font(.system(size: capsuleFontSize, weight: .bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if style.showConfidence {
                    Text(percentText)
                        .font(.system(size: capsuleFontSize, weight: .bold).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if isUncertain {
                    uncertaintyDot
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7 * scale)
            .padding(.vertical, 4 * scale)
            .background(bin.color, in: Capsule())
        }
    }

    @ViewBuilder
    private var dirtyRecyclableBadge: some View {
        if style.isIconOnly {
            ZStack(alignment: .center) {
                Circle()
                    .fill(bin.color)
                    .frame(width: badgeSize, height: badgeSize)
                    .overlay {
                        Image(systemName: BinGuide.residual.symbolName)
                            .font(.system(size: iconOnlyFontSize, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: -badgeSize * 0.22, y: 0)
                Circle()
                    .fill(recyclableBin.color)
                    .frame(width: badgeSize * 1.12, height: badgeSize * 1.12)
                    .overlay {
                        Image(systemName: BinGuide.cleanInorganic.symbolName)
                            .font(.system(size: iconOnlyFontSize, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: badgeSize * 0.28, y: 0)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
            .frame(width: badgeSize * 1.6, height: badgeSize * 1.12)
        } else {
            HStack(spacing: 0) {
                HStack(spacing: 4 * scale) {
                    if style.showIcon {
                        Image(systemName: BinGuide.residual.symbolName)
                            .font(.system(size: capsuleFontSize, weight: .bold))
                    }
                    if style.showCategory {
                        Text(BinGuide.residual.displayName)
                            .font(.system(size: capsuleFontSize, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if style.showConfidence {
                        Text(percentText)
                            .font(.system(size: capsuleFontSize, weight: .bold).monospacedDigit())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7 * scale)
                .padding(.vertical, 4 * scale)
                .background(bin.color, in: Capsule())

                Circle()
                    .fill(recyclableBin.color)
                    .frame(width: badgeSize * 1.05, height: badgeSize * 1.05)
                    .overlay {
                        Image(systemName: BinGuide.cleanInorganic.symbolName)
                            .font(.system(size: iconOnlyFontSize, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: -6 * scale)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
        }
    }
}

#Preview("Dirty recyclable box") {
    ZStack {
        Color.black
        DetectionBoxView(
            bin: BinGuide.residual,
            recyclableBin: BinGuide.cleanInorganic,
            isDirtyRecyclable: true,
            rect: CGRect(x: 80, y: 160, width: 180, height: 240),
            confidence: 0.72,
            confirmation: .confirmed
        )
    }
    .ignoresSafeArea()
}
