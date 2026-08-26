import Foundation

nonisolated struct SettingsSearchHit: Hashable, Identifiable, Sendable {
    let pane: SettingsPane
    let title: String

    var id: String { "\(pane.rawValue).\(title)" }
}

nonisolated enum SettingsSearch {
    static func matches(_ query: String) -> [SettingsSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return catalog.filter { $0.title.localizedStandardContains(needle) }
    }

    static let catalog: [SettingsSearchHit] = SettingsPane.allCases.flatMap { pane in
        pane.searchTitles.map { SettingsSearchHit(pane: pane, title: $0) }
    }
}
