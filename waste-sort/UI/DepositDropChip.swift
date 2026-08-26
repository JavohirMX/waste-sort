import SwiftUI

/// Explains a throw that was seen but not credited — the silent failure that
/// used to make kiosks look broken with zero evidence.
struct DepositDropChip: View {
    let drop: DepositDrop

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch drop.reason {
        case .outsideZones: "scope.slash"
        case .binReadShut: "door.left.hand.closed"
        }
    }

    private var message: String {
        switch drop.reason {
        case .outsideZones:
            return "That throw didn't count — it vanished outside every bin zone."
        case .binReadShut:
            let bin = drop.targetBinID.flatMap { BinGuide.bin(id: $0).displayName } ?? "the bin"
            return "That throw didn't count — \(bin) read shut. Check its strip is visible."
        }
    }
}
