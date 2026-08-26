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

            VStack(alignment: .leading, spacing: isWide ? 24 : 16) {
                header
                    .padding(.leading, 56)

                binCardsRow
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                orientationStrip

                saveFooter
                    .padding(.bottom, isWide ? 8 : 4)
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bin Settings")
                    .font(.system(size: isWide ? 45 : 34, weight: .bold, design: .default))
                    .foregroundStyle(Color.black)
                Text("Drag the cards so they can match your actual bins, left to right")
                    .font(.system(size: isWide ? 24 : 16, weight: .regular, design: .default))
                    .foregroundStyle(Color(red: 121 / 255, green: 121 / 255, blue: 121 / 255))
            }

            Spacer(minLength: 0)

            resetButton
        }
    }

    private var resetButton: some View {
        Button {
            binStyle.resetToDefaults()
        } label: {
            Label("Reset to Default", systemImage: "arrow.counterclockwise")
                .font(.system(size: isWide ? 16 : 13, weight: .medium, design: .default))
                .foregroundStyle(Color(white: 0.10))
                .padding(.horizontal, isWide ? 20 : 14)
                .padding(.vertical, isWide ? 12 : 8)
                .background {
                    Capsule(style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset to Default")
    }

    /// The design anchors the whole screen on where people actually stand, so the bins can
    /// be dragged into the order they are seen in rather than an abstract one.
    private var orientationStrip: some View {
        VStack(spacing: isWide ? 12 : 6) {
            Image(systemName: "person.3.fill")
                .font(.system(size: isWide ? 64 : 32, weight: .regular))
                .foregroundStyle(Color.black)
            Text("People interact with the bins from here")
                .font(.system(size: isWide ? 22 : 14, weight: .regular, design: .default))
                .foregroundStyle(Color.black)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isWide ? 28 : 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.50))
        )
    }

    private var saveFooter: some View {
        VStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Text("Save")
                    .font(.system(size: isWide ? 24 : 17, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .frame(maxWidth: isWide ? 517 : .infinity)
                    .frame(height: isWide ? 78 : 50)
                    .background(
                        Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255),
                        in: Capsule(style: .continuous)
                    )
                    .glassEffect(.clear.interactive(), in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.04), radius: 15, y: 8)

            Text("Preview")
                .font(.system(size: isWide ? 22 : 14, weight: .medium, design: .default))
                .foregroundStyle(Color.black.opacity(0.40))
        }
        .frame(maxWidth: .infinity)
    }

    private var binCardsRow: some View {
        let bins = binStyle.orderedBins
        let spacing: CGFloat = isWide ? 22 : 14

        return HStack(spacing: spacing) {
            ForEach(bins) { bin in
                BinArrangementCard(bin: bin, isWide: isWide) {
                    draft = binStyle.customization(for: bin.id)
                }
                .opacity(draggingID == bin.id ? 0.55 : 1)
                .popover(item: popoverBinding(for: bin.id)) { presented in
                    BinDetailsEditor(
                        draft: Binding(
                            get: { draft ?? presented },
                            set: { draft = $0 }
                        ),
                        onCancel: discardDraft,
                        onSave: saveDraft
                    )
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(.ultraThinMaterial)
                    .presentationCornerRadius(20)
                }
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
    }

    private func applyReorder(from sourceID: String, to targetID: String) {
        var ids = binStyle.orderedBins.map(\.id)
        guard let from = ids.firstIndex(of: sourceID),
              let to = ids.firstIndex(of: targetID),
              from != to
        else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.easeInOut(duration: 0.2)) {
            binStyle.reorder(
                orderedBinIDs: ids,
                zoneStore: zoneStore,
                rotation: settings.liveRotation,
                mirror: settings.liveMirror
            )
        }
    }

    /// One popover per card, so the panel anchors to the bin it edits the way the design
    /// floats it beside the card rather than sliding it up from the bottom.
    private func popoverBinding(for binID: String) -> Binding<BinCustomization?> {
        Binding(
            get: { draft?.binID == binID ? draft : nil },
            set: { draft = $0 }
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

/// A bin as the design draws it: flat accent, name and description settled into the
/// bottom-left, and an explicit pencil rather than relying on the card itself being tapped.
#Preview {
    NavigationStack {
        BinSettingsView()
            .environmentObject(BinStyleStore.shared)
            .environmentObject(ZoneStore.shared)
            .environmentObject(AppSettings.shared)
    }
}
