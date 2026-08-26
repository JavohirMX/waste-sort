import AVFoundation
import SwiftUI
import UIKit

/// Page 6's artwork band — a placement photo next to the real camera feed, so the user can
/// aim the camera against the reference while the instructions are still in front of them.
struct CameraSetupMedia: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var camera = OnboardingCameraModel()
    @Environment(\.onboardingMetrics) private var m

    var body: some View {
        HStack(spacing: m.s(20)) {
            // The reference photo already has "Camera Placement" printed onto it, so no label
            // overlay is added here — only the live feed needs one drawn in code.
            OnboardingMediaCard(
                imageName: "ob-camera-placement",
                width: m.s(466),
                height: m.s(469)
            )

            liveCard
        }
        .task { await camera.start(preferenceID: settings.preferredCameraID) }
        .onDisappear { camera.stop() }
    }

    private var liveCard: some View {
        ZStack {
            switch camera.status {
            case .running:
                OnboardingCameraPreview(session: camera.session)
                    .scaleEffect(x: settings.liveMirror ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(settings.liveRotation.degrees))
            case .denied:
                unavailableCard(
                    symbol: "video.slash",
                    message: "Camera access is off. Turn it on in Settings to see the live view.",
                    actionTitle: "Open Settings",
                    action: openSystemSettings
                )
            case .unavailable:
                unavailableCard(
                    symbol: "camera.badge.ellipsis",
                    message: "No camera found. Connect the USB-C camera and it will appear here.",
                    actionTitle: nil,
                    action: nil
                )
            case .idle:
                Color.black.opacity(0.06)
            }
        }
        .frame(width: m.s(624), height: m.s(469))
        .clipShape(
            RoundedRectangle(
                cornerRadius: m.s(Theme.onboardingCardCornerRadius),
                style: .continuous
            )
        )
        .overlay(alignment: .top) {
            OnboardingLabelPill {
                HStack(spacing: m.s(6)) {
                    Image(systemName: "circle.fill")
                        .font(BrandFont.body(m.s(9)))
                        .foregroundStyle(.red)
                    Text("Camera Live Vision")
                }
            }
        }
    }

    private func unavailableCard(
        symbol: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: m.s(16)) {
            Image(systemName: symbol)
                .font(BrandFont.body(m.s(44), weight: .light))
                .foregroundStyle(.black.opacity(0.35))

            Text(message)
                .font(BrandFont.body(m.s(20)))
                .foregroundStyle(.black.opacity(Theme.onboardingSubtitleOpacity))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                UnderlinedLinkButton(title: actionTitle, fontSize: m.s(20), action: action)
            }
        }
        .padding(m.s(40))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.04))
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The small caption pill sitting inside the top edge of a media card — matches the warm cream
/// tag printed onto the reference photo itself, so the live feed's label reads as the same tag.
struct OnboardingLabelPill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.onboardingMetrics) private var m

    var body: some View {
        content()
            .font(BrandFont.body(m.s(15), weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, m.s(14))
            .frame(height: m.s(30))
            .background {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.95, green: 0.90, blue: 0.82),
                                Color(red: 0.88, green: 0.80, blue: 0.65),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color(red: 0.79, green: 0.66, blue: 0.47).opacity(0.6))
                    }
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            }
            .padding(.top, m.s(14))
    }
}
