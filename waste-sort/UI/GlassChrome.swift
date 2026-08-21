import SwiftUI

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
