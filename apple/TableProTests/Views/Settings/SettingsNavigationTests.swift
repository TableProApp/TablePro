//
//  SettingsNavigationTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct SettingsNavigationTests {
    @Test("Every pane appears exactly once across the sections")
    func sectionsCoverEveryPaneOnce() {
        let flattened = SettingsNavigation.sections.flatMap(\.panes)
        #expect(flattened == SettingsNavigation.orderedPanes)
        #expect(flattened.count == SettingsPane.allCases.count)
        #expect(Set(flattened) == Set(SettingsPane.allCases))
    }

    @Test("The default pane is General and is in the order")
    func defaultPaneIsInOrder() {
        #expect(SettingsNavigation.defaultPane == .general)
        #expect(SettingsNavigation.orderedPanes.contains(.general))
    }

    @Test("A url identifier round-trips to its pane")
    func urlIdentifierRoundTrips() {
        for pane in SettingsPane.allCases {
            #expect(SettingsNavigation.pane(forURLIdentifier: pane.urlIdentifier) == pane)
        }
        #expect(SettingsNavigation.pane(forURLIdentifier: "license") == .account)
        #expect(SettingsNavigation.pane(forURLIdentifier: "plugins") == .plugins)
        #expect(SettingsNavigation.pane(forURLIdentifier: "nope") == nil)
    }

    @Test("An empty query returns the whole order")
    func emptyQueryReturnsEverything() {
        #expect(SettingsNavigation.panes(matching: "") == SettingsNavigation.orderedPanes)
        #expect(SettingsNavigation.panes(matching: "   ") == SettingsNavigation.orderedPanes)
    }

    @Test("Search matches titles and keywords, case-insensitively")
    func searchMatchesTitlesAndKeywords() {
        #expect(SettingsNavigation.panes(matching: "theme") == [.appearance])
        #expect(SettingsNavigation.panes(matching: "shortcut") == [.keyboard])
        #expect(SettingsNavigation.panes(matching: "MCP") == [.mcp])
        #expect(SettingsNavigation.panes(matching: "sql format") == [.editor])
        #expect(SettingsNavigation.panes(matching: "license") == [.account])
        #expect(SettingsNavigation.panes(matching: "zzzznomatch").isEmpty)
    }

    @Test("Search results keep sidebar order")
    func searchResultsKeepSidebarOrder() {
        // "connections" is a General keyword and the Connections concept; results stay in order.
        let results = SettingsNavigation.panes(matching: "e")
        let orderIndex = SettingsNavigation.orderedPanes.enumerated()
            .reduce(into: [SettingsPane: Int]()) { $0[$1.element] = $1.offset }
        let indices = results.compactMap { orderIndex[$0] }
        #expect(indices == indices.sorted())
    }
}
