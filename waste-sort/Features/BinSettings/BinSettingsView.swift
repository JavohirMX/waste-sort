import SwiftUI
import UniformTypeIdentifiers

struct BinSettingsView: View {
    @EnvironmentObject private var binStyle: BinStyleStore
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var draft: BinCustomization?
    @State private var draggingID: String?

    private var isWide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ZStack {
            Theme.statsBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: isWide ? 28 : 20) {
                header
                    .padding(.leading, 56)

                binCardsRow
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text("Drag and Drop to sort, tap to edit details.")
                    .font(.system(size: isWide ? 17 : 15, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, isWide ? 20 : 12)
            }
            .padding(.horizontal, GlassChrome.pageInset)
            .padding(.top, 20)
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            GlassChrome.glassCircleButton(
                systemName: "chevron.left",
                accessibilityLabel: "Back"
            ) {
                dismiss()
            }
            .padding(.top, 16)
            .padding(.leading, GlassChrome.pageInset)
        }
        .sheet(item: $draft) { presented in
            BinDetailsEditor(
                draft: Binding(
                    get: { draft ?? presented },
                    set: { draft = $0 }
                ),
                onCancel: discardDraft,
                onSave: saveDraft
            )
            .presentationDetents([.height(420), .medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bin Settings")
                .font(.system(size: isWide ? 42 : 34, weight: .bold, design: .default))
                .foregroundStyle(Color(white: 0.12))
            Text("How are your bins arranged?")
                .font(.system(size: isWide ? 20 : 17, weight: .regular, design: .default))
                .foregroundStyle(.secondary)
        }
    }

    private var binCardsRow: some View {
        HStack(spacing: isWide ? 22 : 14) {
            ForEach(binStyle.orderedBins) { bin in
                BinArrangementCard(bin: bin, isWide: isWide)
                    .opacity(draggingID == bin.id ? 0.55 : 1)
                    .onTapGesture {
                        draft = binStyle.customization(for: bin.id)
                    }
                    .onDrag {
                        draggingID = bin.id
                        return NSItemProvider(object: bin.id as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: BinReorderDropDelegate(
                            targetID: bin.id,
                            draggingID: $draggingID,
                            orderedIDs: binStyle.orderedBins.map(\.id),
                            onMove: applyReorder
                        )
                    )
            }
        }
        .padding(isWide ? 28 : 18)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.white.opacity(0.55))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        )
    }

    private func applyReorder(from sourceID: String, to targetID: String) {
        var ids = binStyle.orderedBins.map(\.id)
        guard let from = ids.firstIndex(of: sourceID),
              let to = ids.firstIndex(of: targetID),
              from != to
        else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        binStyle.reorder(
            orderedBinIDs: ids,
            zoneStore: zoneStore,
            rotation: settings.liveRotation,
            mirror: settings.liveMirror
        )
    }

    private func discardDraft() {
        draft = nil
    }

    private func saveDraft() {
        guard var draft else { return }
        draft.clampLabel()
        if draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.label = BinGuide.bin(id: draft.binID).displayName.capitalized
        }
        binStyle.updateCustomization(draft)
        self.draft = nil
    }
}

private struct BinArrangementCard: View {
    let bin: BinInfo
    var isWide: Bool = true

    var body: some View {
        VStack(spacing: isWide ? 22 : 16) {
            Spacer(minLength: 0)
            Image(systemName: bin.symbolName)
                .font(.system(size: isWide ? 48 : 36, weight: .bold))
                .foregroundStyle(.white)
            Text(bin.displayName)
                .font(.system(size: isWide ? 18 : 15, weight: .bold, design: .default))
                .tracking(0.9)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(isWide ? 22 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [bin.color, bin.color.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: bin.color.opacity(0.35), radius: 12, y: 5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bin.displayName)
        .accessibilityHint("Double tap to edit. Drag to reorder.")
    }
}

/// Sheet editor: circle X, title, blue check, three inset rows.
private struct BinDetailsEditor: View {
    @Binding var draft: BinCustomization
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.25))
                        .frame(width: 34, height: 34)
                        .background(Color(white: 0.9), in: Circle())
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
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: Circle())
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

            VStack(alignment: .leading, spacing: 10) {
                Text("Colour")
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundStyle(Color(white: 0.12))

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7),
                    spacing: 10
                ) {
                    ForEach(BinColorToken.allCases) { token in
                        let selected = draft.colorToken == token.rawValue
                        Button {
                            draft.colorToken = token.rawValue
                        } label: {
                            Circle()
                                .fill(token.color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            selected ? Color.accentColor : Color.black.opacity(0.12),
                                            lineWidth: selected ? 2.5 : 1
                                        )
                                )
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(token == .yellow || token == .mint ? Color(white: 0.2) : .white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(token.rawValue.capitalized)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(12)
                .background(Color(white: 0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.98, green: 0.97, blue: 0.94))
    }

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
        .padding(.vertical, 14)
        .background(Color(white: 0.9), in: Capsule())
    }
}

private struct BinReorderDropDelegate: DropDelegate {
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

#Preview {
    NavigationStack {
        BinSettingsView()
            .environmentObject(BinStyleStore.shared)
            .environmentObject(ZoneStore.shared)
            .environmentObject(AppSettings.shared)
    }
}
