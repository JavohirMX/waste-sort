import SwiftUI

/// Fills one category-bar segment: checkmark for a correct throw, "Not here!" for a miss.
struct ThrowFeedbackSegmentOverlay: View {
    let feedback: ThrowFeedback
    var replayID: UInt64 = 0
    @Environment(\.hudTextScale) private var hudTextScale

    var body: some View {
        Group {
            switch feedback {
            case .correct:
                correctOverlay
            case .incorrect:
                incorrectOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private var correctOverlay: some View {
        let badge = min(28 * hudTextScale, Theme.barHeight - 16)
        return ZStack {
            feedback.bin.color
            Circle()
                .fill(.white)
                .frame(width: badge, height: badge)
            Image(systemName: "checkmark")
                .font(.system(size: badge * 0.5, weight: .bold))
                .foregroundStyle(feedback.bin.color)
        }
    }

    private var incorrectOverlay: some View {
        NotHereContent(textScale: hudTextScale)
            .id(replayID)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.throwFeedbackIncorrect)
    }
}

/// Icon + copy match `CategorySegment` (16pt symbol, 14pt label). Both shake together.
private struct NotHereContent: View {
    var textScale: CGFloat = 1
    @State private var shake = false

    var body: some View {
        HStack(spacing: 8 * textScale) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16 * textScale, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.throwFeedbackIncorrect, .white)
            Text("Not here!")
                .font(.system(size: 14 * textScale, weight: .semibold))
                .tracking(0.6)
                .lineLimit(1)
                .foregroundStyle(.white)
        }
        .keyframeAnimator(initialValue: ShakeFrame(), trigger: shake) { content, frame in
            content
                .offset(x: frame.offset)
                .rotationEffect(.degrees(frame.rotation))
        } keyframes: { _ in
            KeyframeTrack(\.offset) {
                LinearKeyframe(36, duration: 0.04)
                LinearKeyframe(-36, duration: 0.05)
                LinearKeyframe(28, duration: 0.05)
                LinearKeyframe(-22, duration: 0.05)
                LinearKeyframe(14, duration: 0.04)
                LinearKeyframe(-8, duration: 0.04)
                LinearKeyframe(0, duration: 0.04)
            }
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(Theme.animationDuration))
                shake = true
            }
        }
    }
}

private struct ShakeFrame {
    var offset: CGFloat = 0
    var rotation: Double = 0
}

#Preview("Correct segment") {
    ThrowFeedbackSegmentOverlay(feedback: .correct(binID: BinGuide.organic.id))
        .frame(width: 220, height: Theme.barHeight)
}

#Preview("Incorrect segment") {
    ThrowFeedbackSegmentOverlay(feedback: .incorrect(binID: BinGuide.organic.id))
        .frame(width: 220, height: Theme.barHeight)
}
