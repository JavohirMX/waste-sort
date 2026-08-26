import SwiftUI
import UniformTypeIdentifiers

struct BinSettingsView: View {
    @EnvironmentObject private var binStyle: BinStyleStore
    @EnvironmentObject private var zoneStore: ZoneStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var binPreview: BinPreviewCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var draft: BinCustomization?
    @State private var draggingID: String?

    private var isWide: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ZStack {
            Theme.statsSettingsBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: isWide ? 24 : 16) {
                header

                binCardsRow
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                orientationStrip

                saveFooter
                    .padding(.bottom, isWide ? 8 : 4)
            }
            .padding(.horizontal, GlassChrome.pageInset)
            .padding(.top, 16 + GlassChrome.circleSize + 24)
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
            GlassCapsuleButton(
                "Save",
                height: isWide ? 78 : 50,
                fontSize: isWide ? 24 : 17,
                action: { dismiss() }
            )
            .frame(maxWidth: isWide ? 517 : .infinity)

            Button {
                binPreview.returnsToBinSettings = true
                binPreview.isActive = true
            } label: {
                Text("Preview")
                    .font(.system(size: isWide ? 22 : 14, weight: .medium, design: .default))
                    .foregroundStyle(Color.black.opacity(0.40))
            }
            .buttonStyle(.plain)
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

/// A bin as the design draws it: flat accent, name and description centered in the card,
/// and an explicit pencil rather than relying on the card itself being tapped.
private struct BinArrangementCard: View {
    let bin: BinInfo
    var isWide: Bool = true
    var onEdit: () -> Void

    private var cornerRadius: CGFloat { 20 }

    var body: some View {
        VStack(spacing: isWide ? 8 : 4) {
            HStack(spacing: isWide ? 10 : 7) {
                Image(systemName: bin.symbolName)
                    .font(.system(size: isWide ? 34 : 21, weight: .bold))
                Text(bin.displayName.capitalized)
                    .font(.system(size: isWide ? 34 : 21, weight: .bold, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)

            Text(Self.caption(for: bin.id))
                .font(.system(size: isWide ? 22 : 14, weight: .regular, design: .default))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(isWide ? 24 : 16)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Self.gradient(for: bin.id))
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: isWide ? 24 : 24, weight: .bold))
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

    /// A short example-items caption for the card — distinct from `BinInfo.instructions`,
    /// which is detection-model guidance rather than user-facing copy.
    private static func caption(for binID: String) -> String {
        switch binID {
        case BinGuide.organic.id: return "Food scraps, tea bags, napkins"
        case BinGuide.residual.id: return "Food wrapper, tissue, sachets"
        case BinGuide.cleanInorganic.id: return "Bottles, cans, clean plastic"
        default: return ""
        }
    }

    /// The design's per-card gradient — distinct from `BinInfo.color`/`idleColor`, which
    /// drive the live detection UI rather than this settings card.
    private static func gradient(for binID: String) -> LinearGradient {
        let stops: (top: Color, bottom: Color) = {
            switch binID {
            case BinGuide.organic.id:
                return (
                    Color(red: 0x1F / 255, green: 0x7A / 255, blue: 0x36 / 255).opacity(0.80),
                    Color(red: 0x35 / 255, green: 0xCA / 255, blue: 0x5A / 255).opacity(0.80)
                )
            case BinGuide.residual.id:
                return (
                    Color(red: 0x02 / 255, green: 0x0C / 255, blue: 0x04 / 255).opacity(0.80),
                    Color(red: 0x0A / 255, green: 0x0F / 255, blue: 0x0B / 255).opacity(0.70)
                )
            case BinGuide.cleanInorganic.id:
                return (
                    Color(red: 0xDF / 255, green: 0xBB / 255, blue: 0x2F / 255),
                    Color(red: 0xFC / 255, green: 0xD3 / 255, blue: 0x31 / 255)
                )
            default:
                return (Color.gray, Color.gray)
            }
        }()
        return LinearGradient(colors: [stops.top, stops.bottom], startPoint: .top, endPoint: .bottom)
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
                GlassChrome.glassCircleButton(
                    systemName: "xmark",
                    accessibilityLabel: "Cancel",
                    action: onCancel
                )

                Spacer()

                Text("Bin Details")
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .foregroundStyle(Color(white: 0.12))

                Spacer()

                Button(action: onSave) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: GlassChrome.circleSize, height: GlassChrome.circleSize)
                        .background {
                            Circle()
                                .fill(.clear)
                                .glassEffect(.regular.tint(.blue).interactive(), in: Circle())
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save")
            }

            VStack(spacing: 8) {
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
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .padding(.top, 12)
        .frame(width: Self.cardWidth, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(.white.opacity(0.6)),
                    in: RoundedRectangle(cornerRadius: 32, style: .continuous)
                )
        }
        .shadow(color: .black.opacity(0.30), radius: 50, y: 10)
    }

    /// The panel is a fixed-width floating card; height follows its content.
    static let cardWidth: CGFloat = 382

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
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(red: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE4 / 255).opacity(0.8), in: Capsule())
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
            .environmentObject(BinPreviewCoordinator.shared)
    }
}
