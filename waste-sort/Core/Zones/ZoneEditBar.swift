import SwiftUI

/// Live-tab chrome shown while calibrating zones.
struct ZoneEditBar: View {
    let zones: [DropZone]
    @Binding var selectedZoneID: UUID?
    var onReset: () -> Void
    var onDone: () -> Void

    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Drag the corners onto each bin")
                    .font(.system(.footnote, design: .default).weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer(minLength: 0)

                Button("Reset") { showResetConfirm = true }
                    .font(.system(.footnote, design: .default).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Button("Done", action: onDone)
                    .font(.system(.footnote, design: .default).weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .tint(BinGuide.organic.color)
                    .controlSize(.small)
            }

            if zones.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(title: "All", color: .white, isSelected: selectedZoneID == nil) {
                            selectedZoneID = nil
                        }
                        ForEach(zones) { zone in
                            chip(
                                title: zone.name,
                                color: zone.bin.color,
                                isSelected: selectedZoneID == zone.id
                            ) {
                                selectedZoneID = zone.id
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .confirmationDialog(
            "Reset zones to defaults?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset zones", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chip(
        title: String,
        color: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color : color.opacity(0.22), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
