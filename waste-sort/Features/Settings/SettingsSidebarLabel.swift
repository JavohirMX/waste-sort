import SwiftUI

struct SettingsSidebarLabel: View {
    let title: String
    let systemImage: String
    let iconColor: Color
    var subtitle: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(iconColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
