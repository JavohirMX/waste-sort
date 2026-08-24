import SwiftUI

/// Live HUD chip for an AFM dirty-recyclable lock: residual or recyclable if rinsed.
struct DirtyRecyclableSuggestionChip: View {
    var body: some View {
        HStack(spacing: 10) {
            splitIcon
            (Text("If cleaned, can be ") + Text("Recyclable").fontWeight(.bold))
                .font(.system(.footnote, design: .default))
                .foregroundStyle(.white)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("If cleaned, can be Recyclable")
    }

    private var splitIcon: some View {
        ZStack {
            residualHalf
            recyclableHalf
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0), lineWidth: 1)
        }
    }

    private var residualHalf: some View {
        Circle()
            .fill(BinGuide.residual.color)
            .overlay(alignment: .topLeading) {
                Image(systemName: BinGuide.residual.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
            }
            .mask {
                Rectangle()
                    .rotationEffect(.degrees(-45))
                    .offset(x: -12, y: -12)
            }
    }

    private var recyclableHalf: some View {
        Circle()
            .fill(BinGuide.cleanInorganic.color)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: BinGuide.cleanInorganic.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
            }
            .mask {
                Rectangle()
                    .rotationEffect(.degrees(45))
                    .offset(x: 12, y: 12)
            }
    }
}


#Preview {
    ZStack {
        Color.black
        DirtyRecyclableSuggestionChip()
    }
    .ignoresSafeArea()
}
