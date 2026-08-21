import SwiftUI
import UIKit

/// Shared Liquid Glass chrome for Stats / Bin Settings floating controls.
enum GlassChrome {
    static let iconForeground = Color(white: 0.22)
    static let circleSize: CGFloat = 48
    static let cardCornerRadius: CGFloat = 28
    static let pageInset: CGFloat = 28
    /// Inner corner radius for edge-docked half-pill tabs.
    static let edgeTabRadius: CGFloat = 24

    enum Edge {
        case leading
        case trailing
    }

    static func glassCircleButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconForeground)
                .frame(width: circleSize, height: circleSize)
                .background {
                    Circle()
                        .fill(.clear)
                        .glassEffect(.regular, in: Circle())
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    static func glassCapsuleLabel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .foregroundStyle(iconForeground)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular, in: Capsule())
            }
    }

    /// Half-pill docked to the screen edge: square on the flush side, rounded on the inner side.
    static func edgeTabLabel<Content: View>(
        edge: Edge,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = edgeTabShape(edge: edge)
        return content()
            .foregroundStyle(iconForeground)
            .padding(.vertical, 14)
            .padding(.leading, edge == .leading ? 14 : 18)
            .padding(.trailing, edge == .trailing ? 14 : 18)
            .background {
                shape
                    .fill(.clear)
                    .glassEffect(.regular, in: shape)
            }
    }

    private static func edgeTabShape(edge: Edge) -> UnevenRoundedRectangle {
        switch edge {
        case .leading:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: edgeTabRadius,
                topTrailingRadius: edgeTabRadius,
                style: .continuous
            )
        case .trailing:
            UnevenRoundedRectangle(
                topLeadingRadius: edgeTabRadius,
                bottomLeadingRadius: edgeTabRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        }
    }
}

/// Frosted backdrop that blurs whatever is behind it (the live camera when Stats is an overlay).
struct CameraGlassBackdrop: View {
    var body: some View {
        ZStack {
            CameraBlurView()
            Theme.statsBackground.opacity(0.14)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// UIKit blur samples the window compositor, including `AVCaptureVideoPreviewLayer`.
private struct CameraBlurView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

/// SwiftUI `NavigationStack` sits in an opaque `UINavigationController`. Clear it so glass can see the camera.
struct ClearHostingBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = HostingBackgroundClearView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? HostingBackgroundClearView)?.clearOpaqueAncestors()
    }
}

private final class HostingBackgroundClearView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        clearOpaqueAncestors()
    }

    func clearOpaqueAncestors() {
        var responder: UIResponder? = self
        while let current = responder {
            if let nav = current as? UINavigationController {
                nav.view.backgroundColor = .clear
                nav.view.isOpaque = false
                nav.navigationBar.isTranslucent = true
            }
            responder = current.next
        }

        var view: UIView? = superview
        var hops = 0
        while let current = view, hops < 16, !(current is UIWindow) {
            if !(current is UIVisualEffectView) {
                current.backgroundColor = .clear
                current.isOpaque = false
            }
            view = current.superview
            hops += 1
        }
    }
}

struct StatsCardSurface<Content: View>: View {
    var padding: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: GlassChrome.cardCornerRadius, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
            )
    }
}
