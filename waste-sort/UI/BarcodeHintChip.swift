import SwiftUI

/// Bottom-HUD chip surfacing a barcode found in the live feed, with an
/// offline disposal hint. Appears for a few seconds per scan.
struct BarcodeHintChip: View {
    let barcode: ScannedBarcode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(barcode.payload)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(BarcodeGuidance.displayName(for: barcode.symbology)) · \(BarcodeGuidance.hint(for: barcode.symbology))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Barcode \(barcode.payload). \(BarcodeGuidance.hint(for: barcode.symbology))")
    }
}
