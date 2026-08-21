import SwiftUI

/// The "Button - Liquid Glass - Text" call to action from the design: a green capsule with a
/// glass sheen over it.
struct GlassCapsuleButton<Label: View>: View {
    /// Design point values are scaled by the caller, so pass the already-scaled height.
    var height: CGFloat
    var tint: Color = Theme.onboardingAccent
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                // The design layers a glass effect over a solid fill. Keeping the fill as a
                // real background means the button stays visible when the system declines to
                // render glass (Reduce Transparency, offscreen rendering).
                .background(tint, in: Capsule(style: .continuous))
                .glassEffect(.clear.interactive(), in: Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.02), radius: 15, y: 8)
    }
}

extension GlassCapsuleButton where Label == Text {
    /// Convenience for the common case: a bold white title.
    init(
        _ title: String,
        height: CGFloat,
        fontSize: CGFloat,
        tint: Color = Theme.onboardingAccent,
        action: @escaping () -> Void
    ) {
        self.init(height: height, tint: tint, action: action) {
            Text(title)
                .font(BrandFont.body(fontSize, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// The underlined text links in the flow — "Skip" and "Already set up".
struct UnderlinedLinkButton: View {
    let title: String
    var fontSize: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(fontSize, weight: .medium))
                .foregroundStyle(.black)
                .underline()
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        Theme.onboardingBackground
        VStack(spacing: 24) {
            GlassCapsuleButton("Continue", height: 78, fontSize: 24) {}
                .frame(width: 515)
            UnderlinedLinkButton(title: "Already set up", fontSize: 20) {}
        }
    }
    .ignoresSafeArea()
}
