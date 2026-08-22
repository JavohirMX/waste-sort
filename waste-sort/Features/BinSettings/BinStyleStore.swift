import Combine
import Foundation
import SwiftUI

/// Persisted display overrides for the three ML bins (label, icon, colour, order).
nonisolated struct BinCustomization: Codable, Equatable, Sendable, Identifiable {
    var binID: String
    var label: String
    var symbolName: String
    var colorToken: String
    var order: Int

    var id: String { binID }

    static let maxLabelLength = 16

    mutating func clampLabel() {
        if label.count > Self.maxLabelLength {
            label = String(label.prefix(Self.maxLabelLength))
        }
    }

    static func clamped(_ label: String) -> String {
        String(label.prefix(maxLabelLength))
    }
}

/// Icons available when editing a bin (design constraint list).
enum BinIconOption: String, CaseIterable, Identifiable {
    case leaf = "leaf.fill"
    case ecoRecycle = "leaf.arrow.triangle.circlepath"
    case sprouts = "camera.macro"
    case tree = "tree.fill"
    case carrot = "carrot.fill"
    case trash = "trash.fill"
    case trashArrow = "arrow.up.trash.fill"
    case recycle = "arrow.3.trianglepath"
    case bottle = "waterbottle.fill"
    case document = "doc.fill"

    var id: String { rawValue }
    var symbolName: String { rawValue }
}

/// Apple accents plus black so Residual can stay dark.
enum BinColorToken: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, black

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: Color(red: 234 / 255, green: 179 / 255, blue: 8 / 255)
        case .green: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .black: Color(red: 39 / 255, green: 39 / 255, blue: 42 / 255)
        }
    }

    var idleColor: Color {
        switch self {
        case .yellow: Color(red: 196 / 255, green: 164 / 255, blue: 106 / 255)
        case .green: Color(red: 107 / 255, green: 143 / 255, blue: 94 / 255)
        case .black: Color(red: 82 / 255, green: 82 / 255, blue: 91 / 255)
        default: color.opacity(0.55)
        }
    }

    static func from(_ raw: String) -> BinColorToken {
        BinColorToken(rawValue: raw) ?? .green
    }
}

@MainActor
final class BinStyleStore: ObservableObject {
    static let shared = BinStyleStore()

    static let defaultSiteName = "Apple Developer Academy Bali"

    @Published var siteName: String {
        didSet { defaults.set(siteName, forKey: Keys.siteName) }
    }

    @Published private(set) var customizations: [BinCustomization] {
        didSet { persistCustomizations() }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let siteName = "binStyle.siteName.v1"
        static let customizations = "binStyle.customizations.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        siteName = defaults.string(forKey: Keys.siteName) ?? Self.defaultSiteName
        if let data = defaults.data(forKey: Keys.customizations),
           let decoded = try? JSONDecoder().decode([BinCustomization].self, from: data),
           Self.isValid(decoded) {
            customizations = decoded.sorted { $0.order < $1.order }
        } else {
            customizations = Self.defaultCustomizations()
        }
    }

    /// Bins in user order, with display overrides applied.
    var orderedBins: [BinInfo] {
        customizations
            .sorted { $0.order < $1.order }
            .map { resolved(BinGuide.bin(id: $0.binID), customization: $0) }
    }

    func customization(for binID: String) -> BinCustomization {
        customizations.first { $0.binID == binID }
            ?? Self.defaultCustomizations().first { $0.binID == binID }
            ?? BinCustomization(
                binID: binID,
                label: BinGuide.bin(id: binID).displayName,
                symbolName: BinGuide.bin(id: binID).symbolName,
                colorToken: "green",
                order: 0
            )
    }

    func resolved(_ info: BinInfo) -> BinInfo {
        resolved(info, customization: customization(for: info.id))
    }

    func resolved(_ info: BinInfo, customization: BinCustomization) -> BinInfo {
        let token = BinColorToken.from(customization.colorToken)
        let label = BinCustomization.clamped(customization.label).uppercased()
        return BinInfo(
            id: info.id,
            title: info.title,
            displayName: label.isEmpty ? info.displayName : label,
            category: info.category,
            bin: info.bin,
            color: token.color,
            idleColor: token.idleColor,
            symbolName: customization.symbolName,
            instructions: info.instructions
        )
    }

    func updateCustomization(_ draft: BinCustomization) {
        var next = draft
        next.clampLabel()
        guard let index = customizations.firstIndex(where: { $0.binID == next.binID }) else { return }
        customizations[index] = next
        customizations.sort { $0.order < $1.order }
    }

    /// Reorders bins and remaps physical zones so left-to-right on screen matches the new order.
    func reorder(
        orderedBinIDs: [String],
        zoneStore: ZoneStore,
        rotation: LivePreviewRotation,
        mirror: Bool
    ) {
        guard orderedBinIDs.count == customizations.count,
              Set(orderedBinIDs) == Set(customizations.map(\.binID))
        else { return }

        var next = customizations
        for (index, binID) in orderedBinIDs.enumerated() {
            guard let i = next.firstIndex(where: { $0.binID == binID }) else { continue }
            next[i].order = index
        }
        customizations = next.sorted { $0.order < $1.order }

        remapZones(
            orderedBinIDs: orderedBinIDs,
            zoneStore: zoneStore,
            rotation: rotation,
            mirror: mirror
        )
    }

    /// Assigns bin IDs to existing zone geometries sorted by on-screen X.
    func remapZones(
        orderedBinIDs: [String],
        zoneStore: ZoneStore,
        rotation: LivePreviewRotation,
        mirror: Bool
    ) {
        let zones = zoneStore.zones
        guard !zones.isEmpty else { return }

        let sortedByScreen = zones.sorted {
            Self.screenX(of: $0, rotation: rotation, mirror: mirror)
                < Self.screenX(of: $1, rotation: rotation, mirror: mirror)
        }

        var remapped = zones
        for (index, zone) in sortedByScreen.enumerated() {
            guard index < orderedBinIDs.count,
                  let storageIndex = remapped.firstIndex(where: { $0.id == zone.id })
            else { continue }
            let binID = orderedBinIDs[index]
            let label = customization(for: binID).label
            remapped[storageIndex].binID = binID
            remapped[storageIndex].name = label.capitalized
        }
        zoneStore.update(remapped)
    }

    static func screenX(
        of zone: DropZone,
        rotation: LivePreviewRotation,
        mirror: Bool
    ) -> CGFloat {
        var point = zone.centroid
        if mirror { point = DetectionGeometry.mirrorNormalized(point) }
        point = DetectionGeometry.rotateNormalized(point, by: rotation)
        return point.x
    }

    func resetToDefaults() {
        siteName = Self.defaultSiteName
        customizations = Self.defaultCustomizations()
    }

    private func persistCustomizations() {
        guard let data = try? JSONEncoder().encode(customizations) else { return }
        defaults.set(data, forKey: Keys.customizations)
    }

    private static func isValid(_ items: [BinCustomization]) -> Bool {
        let ids = Set(items.map(\.binID))
        return ids == Set(BinGuide.all.map(\.id)) && items.count == BinGuide.all.count
    }

    static func defaultCustomizations() -> [BinCustomization] {
        [
            BinCustomization(
                binID: BinGuide.organic.id,
                label: "Organic",
                symbolName: BinIconOption.leaf.symbolName,
                colorToken: BinColorToken.green.rawValue,
                order: 0
            ),
            BinCustomization(
                binID: BinGuide.residual.id,
                label: "Residual",
                symbolName: BinIconOption.trash.symbolName,
                colorToken: BinColorToken.black.rawValue,
                order: 1
            ),
            BinCustomization(
                binID: BinGuide.cleanInorganic.id,
                label: "Recyclable",
                symbolName: BinIconOption.recycle.symbolName,
                colorToken: BinColorToken.yellow.rawValue,
                order: 2
            )
        ]
    }
}
