import SwiftUI

/// Shared layout for onboarding pages 2–7: centred title and subtitle, an artwork band,
/// and the call-to-action stack pinned near the bottom.
///
/// One instance serves every one of those pages, which is what makes the motion work. The
/// artwork is the only element that actually changes place, so it is the only one that moves;
/// the copy swaps in position and the capsule never moves at all — on two of the five steps
/// its label does not even change.
struct OnboardingScaffold: View {
    let page: OnboardingPage
    var direction: OnboardingDirection = .forward
    var onPrimary: () -> Void
    var onSecondary: () -> Void = {}

    @Environment(\.onboardingMetrics) private var m

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: m.s(145))

            Text(page.title)
                .font(BrandFont.display(m.s(58)))
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)

            Text(page.subtitle)
                .font(BrandFont.body(m.s(26)))
                .foregroundStyle(.black.opacity(Theme.onboardingSubtitleOpacity))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, m.s(10))
                .contentTransition(.opacity)

            Spacer(minLength: m.s(16))

            // A ZStack so the outgoing and incoming artwork overlap during the swap instead of
            // briefly stacking and shoving the rest of the page around.
            ZStack {
                OnboardingMedia(page: page)
                    .id(page)
                    .transition(mediaTransition)
            }
            .frame(height: m.s(page.mediaHeight))

            Spacer(minLength: m.s(16))

            VStack(spacing: m.s(10)) {
                GlassCapsuleButton(height: m.s(78), action: onPrimary) {
                    Text(page.primaryTitle)
                        .font(BrandFont.body(m.s(24), weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
                .frame(width: m.s(515))

                if let secondary = page.secondaryTitle {
                    UnderlinedLinkButton(title: secondary, fontSize: m.s(20), action: onSecondary)
                }
            }
        }
        .padding(.horizontal, m.s(30))
        .padding(.bottom, m.s(49))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Arriving artwork slides in from the side the user is travelling towards; leaving artwork
    /// only dissolves. Keeping the removal direction-agnostic matters: SwiftUI reads a removal
    /// transition off the view as it was last rendered, so a directional one would still be
    /// pointing the old way on the step where the user turns around.
    private var mediaTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: m.s(140) * direction.sign)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.94)),
            removal: .opacity.combined(with: .scale(scale: 0.94))
        )
    }
}

/// The back control, the Sortla mark and the Skip link that sit above pages 2–7.
struct OnboardingChrome: View {
    var canGoBack: Bool
    var onBack: () -> Void
    var onSkip: () -> Void
    @Environment(\.onboardingMetrics) private var m

    var body: some View {
        HStack(spacing: m.s(14)) {
            // Held in the layout even when it cannot be used, so the mark beside it never
            // shifts as the user moves through the flow.
            OnboardingBackButton(action: onBack)
                .opacity(canGoBack ? 1 : 0)
                .disabled(!canGoBack)
                .accessibilityHidden(!canGoBack)

            HStack(spacing: m.s(10)) {
                Image(systemName: "arrow.3.trianglepath")
                    .font(BrandFont.body(m.s(24), weight: .medium))
                Text("Sortla")
                    .font(BrandFont.body(m.s(20), weight: .bold))
            }
            .foregroundStyle(.black)

            Spacer()

            UnderlinedLinkButton(title: "Skip", fontSize: m.s(20), action: onSkip)
        }
        .padding(.horizontal, m.s(30))
        .padding(.top, m.s(29))
    }
}

/// Circular glass back control. Not in the design, which has no way back at all — shaped to sit
/// quietly beside the mark rather than compete with the green call to action.
private struct OnboardingBackButton: View {
    var action: () -> Void
    @Environment(\.onboardingMetrics) private var m

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(BrandFont.body(m.s(17), weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: m.s(38), height: m.s(38))
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}

/// The soft cream blob behind the character illustrations, traced from the design vector.
struct OnboardingBlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func r(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        p.move(to: r(0.01980, 0.38645))
        p.addLine(to: r(0.00455, 0.51199))
        p.addCurve(to: r(0.00433, 0.66127), control1: r(-0.00144, 0.56126), control2: r(-0.00151, 0.61196))
        p.addCurve(to: r(0.16965, 0.95892), control1: r(0.02115, 0.80328), control2: r(0.08492, 0.91807))
        p.addLine(to: r(0.22041, 0.98338))
        p.addCurve(to: r(0.29084, 1.00000), control1: r(0.24328, 0.99440), control2: r(0.26700, 1.00000))
        p.addLine(to: r(0.48369, 1.00000))
        p.addLine(to: r(0.78237, 0.97874))
        p.addCurve(to: r(0.98892, 0.72137), control1: r(0.87728, 0.97198), control2: r(0.95963, 0.86937))
        p.addCurve(to: r(0.99724, 0.54864), control1: r(0.99994, 0.66567), control2: r(1.00279, 0.60649))
        p.addLine(to: r(0.99581, 0.53376))
        p.addCurve(to: r(0.97414, 0.42000), control1: r(0.99202, 0.49431), control2: r(0.98472, 0.45598))
        p.addLine(to: r(0.92345, 0.24758))
        p.addCurve(to: r(0.83339, 0.08097), control1: r(0.90342, 0.17947), control2: r(0.87225, 0.12179))
        p.addLine(to: r(0.82217, 0.06919))
        p.addCurve(to: r(0.68749, 0.00452), control1: r(0.78198, 0.02697), control2: r(0.73524, 0.00452))
        p.addLine(to: r(0.48369, 0.00452))
        p.addLine(to: r(0.35965, 0.00452))
        p.addLine(to: r(0.28333, 0.00024))
        p.addCurve(to: r(0.03430, 0.30014), control1: r(0.16794, -0.00623), control2: r(0.06492, 0.11783))
        p.addLine(to: r(0.01980, 0.38645))
        p.closeSubpath()
        return p
    }
}

/// Character artwork centred on the cream blob — pages 2 and 7 share this treatment.
struct OnboardingBlobArtwork: View {
    let imageName: String
    @Environment(\.onboardingMetrics) private var m

    var body: some View {
        ZStack {
            OnboardingBlobShape()
                .fill(Theme.onboardingBlob)
                .frame(width: m.s(810), height: m.s(495))

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: m.s(580), height: m.s(394))
                .offset(y: m.s(6))
        }
        .accessibilityHidden(true)
    }
}

/// A photo of the physical station, clipped to the design's card shape.
struct OnboardingMediaCard: View {
    let imageName: String
    var width: CGFloat
    var height: CGFloat
    @Environment(\.onboardingMetrics) private var m

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: m.s(Theme.onboardingCardCornerRadius),
                    style: .continuous
                )
            )
            .accessibilityHidden(true)
    }
}
