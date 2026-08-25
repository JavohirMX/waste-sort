import Foundation
import Testing

@testable import waste_sort

@Suite("Settings search")
struct SettingsSearchTests {
    @Test("Blank queries produce no hits")
    func blankQueryIsEmpty() {
        #expect(SettingsSearch.matches("").isEmpty)
        #expect(SettingsSearch.matches("   ").isEmpty)
    }

    @Test("Pane names are searchable")
    func paneTitlesAreInCatalog() {
        for pane in SettingsPane.allCases {
            let hits = SettingsSearch.matches(pane.title)
            #expect(hits.contains(where: { $0.pane == pane && $0.title == pane.title }))
        }
    }

    @Test("Matching is case-insensitive and finds the owning pane")
    func caseInsensitiveKnobSearch() {
        let hits = SettingsSearch.matches("dwell")
        #expect(hits.contains(where: { $0.title == "Dwell frames" && $0.pane == .zones }))
    }

    @Test("The same title can appear on more than one pane")
    func duplicateTitlesStayDistinct() {
        let hits = SettingsSearch.matches("confidence")
        let panes = Set(hits.map(\.pane))
        #expect(panes.contains(.overlay))
        #expect(panes.contains(.detection))
    }

    @Test("Every catalog title is unique within its pane")
    func titlesAreUniquePerPane() {
        for pane in SettingsPane.allCases {
            let titles = pane.searchTitles
            #expect(Set(titles).count == titles.count)
        }
    }
}
