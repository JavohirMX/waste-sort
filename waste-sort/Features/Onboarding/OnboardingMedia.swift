import SwiftUI

/// The artwork band for pages 2–7.
///
/// This is the only part of the scaffold that genuinely changes from page to page, so it lives in
/// its own view: the flow gives it a fresh identity on every step and animates it, while the copy
/// and the call to action around it stay put.
struct OnboardingMedia: View {
    let page: OnboardingPage
    @Environment(\.onboardingMetrics) private var m

    var body: some View {
        switch page {
        case .welcome:
            // The welcome screen has its own split layout and never uses this slot.
            EmptyView()

        case .sortWaste:
            artwork("ob-sorting")

        case .trackWaste:
            artwork("ob-tracking")

        case .allSet:
            artwork("ob-general")

        case .meetStation:
            photoCard("ob-station", designWidth: 474)

        case .setUpIPad:
            photoCard("ob-ipad", designWidth: 466)

        case .setUpCamera:
            CameraSetupMedia()
        }
    }

    /// Fixed at the design's 810pt width, keeping the artwork's own aspect ratio.
    private func artwork(_ name: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: m.s(810))
            .accessibilityHidden(true)
    }

    /// Sizes the card off the height the scaffold hands down, keeping the design's aspect ratio
    /// rather than the design's absolute width.
    private func photoCard(_ name: String, designWidth: CGFloat) -> some View {
        GeometryReader { geo in
            OnboardingMediaCard(
                imageName: name,
                width: geo.size.height * (designWidth / 469),
                height: geo.size.height
            )
            .frame(maxWidth: .infinity)
        }
    }
}
