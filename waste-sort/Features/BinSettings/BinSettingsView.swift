import SwiftUI

struct BinSettingsView: View {
    @EnvironmentObject private var binStyle: BinStyleStore
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var draft: BinCustomization?
    @State private var draggingID: String?
    /// Visual offset of the lifted card, and the correction applied each time it changes slot.
    @State private var dragTranslation: CGFloat = 0
    @State private var dragRebase: CGFloat = 0

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
            VStack(alignment: .leading, spacing: 6) {
                Text("Bin Settings")
                    .font(.system(size: isWide ? 42 : 34, weight: .bold, design: .default))
                    .foregroundStyle(Color(white: 0.12))
                Text("Drag the cards so they can match your actual bins, left to right")
                    .font(.system(size: isWide ? 17 : 14, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
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
                .font(.system(size: isWide ? 13 : 12, weight: .medium, design: .default))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Color(white: 0.25))
    }

    /// The design anchors the whole screen on where people actually stand, so the bins can
    /// be dragged into the order they are seen in rather than an abstract one.
    private var orientationStrip: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.3.fill")
                .font(.system(size: isWide ? 26 : 22, weight: .semibold))
                .foregroundStyle(Color(white: 0.2))
            Text("People interact with the bins from here")
                .font(.system(size: isWide ? 14 : 12, weight: .regular, design: .default))
                .foregroundStyle(Color(white: 0.35))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isWide ? 20 : 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.6))
        )
    }

    private var saveFooter: some View {
        VStack(spacing: 6) {
            Button {
                dismiss()
            } label: {
                Text("Save")
                    .font(.system(size: isWide ? 17 : 15, weight: .semibold, design: .default))
                    .frame(maxWidth: isWide ? 460 : .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .controlSize(.large)
            .tint(BinPalette.organic)

            Text("Preview")
                .font(.system(size: isWide ? 13 : 12, weight: .regular, design: .default))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var binCardsRow: some View {
        let bins = binStyle.orderedBins
        let spacing: CGFloat = isWide ? 22 : 14

        return GeometryReader { geo in
            let count = max(bins.count, 1)
            let cardWidth = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            let step = cardWidth + spacing

            HStack(spacing: spacing) {
                ForEach(bins) { bin in
                    let lifted = draggingID == bin.id
                    BinArrangementCard(bin: bin, isWide: isWide) {
                        draft = binStyle.customization(for: bin.id)
                    }
                    .frame(width: cardWidth)
                    .scaleEffect(lifted ? 1.06 : 1)
                    .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: 20, y: 12)
                    .offset(x: lifted ? dragTranslation : 0)
                    .zIndex(lifted ? 1 : 0)
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
                    }
                    .onTapGesture {
                        draft = binStyle.customization(for: bin.id)
                    }
                    .gesture(reorderGesture(for: bin.id, step: step))
                }
            }
            .frame(height: geo.size.height)
        }
    }

    /// Home-screen style rearranging: the lifted card tracks the finger while the others
    /// spring into the gap behind it, and the order commits as each slot is crossed rather
    /// than once on drop.
    private func reorderGesture(for binID: String, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if draggingID == nil {
                    dragRebase = 0
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        draggingID = binID
                    }
                    HapticsService.shared.fire(.lightTap)
                }
                guard draggingID == binID else { return }
                dragTranslation = value.translation.width + dragRebase
                relocate(binID, step: step)
            }
            .onEnded { _ in
                guard draggingID == binID else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.75)) {
                    dragTranslation = 0
                    dragRebase = 0
                    draggingID = nil
                }
            }
    }

    /// Swaps as soon as the card passes into a neighbouring slot, then rebases the visual
    /// offset by the distance it just jumped so it stays put under the finger.
    private func relocate(_ binID: String, step: CGFloat) {
        guard step > 0 else { return }
        var ids = binStyle.orderedBins.map(\.id)
        guard let current = ids.firstIndex(of: binID) else { return }
        let target = min(max(current + Int((dragTranslation / step).rounded()), 0), ids.count - 1)
        guard target != current else { return }

        ids.move(
            fromOffsets: IndexSet(integer: current),
            toOffset: target > current ? target + 1 : target
        )
        let jump = CGFloat(target - current) * step
        dragRebase -= jump
        dragTranslation -= jump

        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
            binStyle.reorder(
                orderedBinIDs: ids,
                zoneStore: zoneStore,
                rotation: settings.liveRotation,
                mirror: settings.liveMirror
            )
        }
        HapticsService.shared.fire(.lightTap)
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
private struct BinArrangementCard: View {
    let bin: BinInfo
    var isWide: Bool = true
    var onEdit: () -> Void

    private var cornerRadius: CGFloat { isWide ? 20 : 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: isWide ? 6 : 4) {
            Spacer(minLength: 0)

            HStack(spacing: isWide ? 9 : 7) {
                Image(systemName: bin.symbolName)
                    .font(.system(size: isWide ? 21 : 17, weight: .bold))
                Text(bin.displayName.capitalized)
                    .font(.system(size: isWide ? 21 : 17, weight: .bold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)

            Text(bin.instructions)
                .font(.system(size: isWide ? 14 : 12, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(isWide ? 18 : 13)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(bin.color)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: isWide ? 13 : 11, weight: .semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .tint(Color(white: 0.25))
            .padding(isWide ? 12 : 9)
            .accessibilityLabel("Edit \(bin.displayName.capitalized)")
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
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
        VStack(spacing: 12) {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(Color(white: 0.25))
                .accessibilityLabel("Cancel")

                Spacer()

                Text("Bin Details")
                    .font(.system(size: 18, weight: .semibold, design: .default))
                    .foregroundStyle(Color(white: 0.12))

                Spacer()

                Button(action: onSave) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
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
        .background(.white)
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

#Preview {
    NavigationStack {
        BinSettingsView()
            .environmentObject(BinStyleStore.shared)
            .environmentObject(ZoneStore.shared)
            .environmentObject(AppSettings.shared)
    }
}
