import SwiftUI

struct TagFailureBanner: View {
    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Bin lid tracking unavailable - deposits count regardless of lids. (\(reason))")
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}
