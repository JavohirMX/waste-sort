import SwiftUI

// MARK: - Bin cards, details editor, and reorder drop delegate

struct BinArrangementCard: View {
    let bin: BinInfo
    var isWide: Bool = true
    var onEdit: () -> Void

    private var cornerRadius: CGFloat { 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: isWide ? 8 : 4) {
            Spacer(minLength: 0)

            HStack(spacing: isWide ? 10 : 7) {
                Image(systemName: bin.symbolName)
                    .font(.system(size: isWide ? 34 : 21, weight: .bold))
                Text(bin.displayName.capitalized)
                    .font(.system(size: isWide ? 34 : 21, weight: .bold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)

            Text(bin.instructions)
                .font(.system(size: isWide ? 22 : 14, weight: .regular, design: .default))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(isWide ? 24 : 16)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [bin.color.opacity(0.80), bin.idleColor.opacity(0.80)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: isWide ? 19 : 14, weight: .bold))
                    .foregroundStyle(Color(white: 0.10))
                    .frame(width: isWide ? 50 : 36, height: isWide ? 50 : 36)
                    .background {
                        Circle()
                            .fill(.clear)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .padding(isWide ? 14 : 9)
            .accessibilityLabel("Edit \(bin.displayName.capitalized)")
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(bin.displayName)
        .accessibilityHint("Double tap to edit. Drag to reorder.")
    }
}

/// Sheet editor: circle X, title, blue check, three inset rows.
struct BinDetailsEditor: View {
    @Binding var draft: BinCustomization
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(white: 0.25))
                        .frame(width: 32, height: 32)
                        .background {
                            Circle()
                                .fill(.clear)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")

                Spacer()

                Text("Bin Details")
                    .font(.system(size: 18, weight: .semibold, design: .default))
                    .foregroundStyle(Color(white: 0.12))

                Spacer()

                Button(action: onSave) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255), in: Circle())
                        .glassEffect(.clear.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save")
            }

            detailRow(title: "Label") {
                TextField("Label", text: labelBinding)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundStyle(Color(white: 0.45))
            }

            Menu {
                ForEach(BinIconOption.allCases) { option in
                    Button {
                        draft.symbolName = option.symbolName
                    } label: {
                        Label(option.symbolName, systemImage: option.symbolName)
                    }
                }
            } label: {
                detailRow(title: "Icon") {
                    HStack(spacing: 6) {
                        Image(systemName: draft.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(white: 0.2))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(BinColorToken.allCases) { token in
                    Button {
                        draft.colorToken = token.rawValue
                    } label: {
                        Label(
                            token.rawValue.capitalized,
                            systemImage: draft.colorToken == token.rawValue
                                ? "checkmark.circle.fill"
                                : "circle.fill"
                        )
                    }
                }
            } label: {
                detailRow(title: "Colour") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(BinColorToken.from(draft.colorToken).color)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 1))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .top)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 50, y: 10)
    }

    /// The panel is a fixed floating card in the design rather than a sheet that grows.
    static let cardSize = CGSize(width: 382, height: 256)

    private var labelBinding: Binding<String> {
        Binding(
            get: { draft.label },
            set: { draft.label = BinCustomization.clamped($0) }
        )
    }

    private func detailRow<Content: View>(
        title: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .medium, design: .default))
                .foregroundStyle(Color(white: 0.12))
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(white: 0.93), in: Capsule())
    }
}

struct BinReorderDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingID: String?
    let orderedIDs: [String]
    let onMove: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID else { return }
        onMove(draggingID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
