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
                .font(BrandFont.body(m.s(57), weight: .bold))
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)

            Text(page.subtitle)
                .font(BrandFont.body(m.s(24)))
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
                    Button(action: onSecondary) {
                        Text(secondary)
                            .font(BrandFont.body(m.s(22), weight: .medium))
                            .foregroundStyle(.black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
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
                Image("sortla-mark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: m.s(48), height: m.s(48))
                    .clipShape(RoundedRectangle(cornerRadius: m.s(12), style: .continuous))
                Text("Sortla")
                    .font(BrandFont.body(m.s(20), weight: .bold))
                    .foregroundStyle(.black)
            }

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
