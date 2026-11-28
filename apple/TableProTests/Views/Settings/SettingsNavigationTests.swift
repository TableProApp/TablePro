import Foundation
@testable import TablePro
import Testing

struct SettingsNavigationTests {
    @Test("The sidebar has four sections in the agreed order")
    func sectionsFollowTheAgreedOrder() {
        #expect(SettingsNavigation.sections.map { $0.id } == [.app, .workspace, .integrations, .account])
        #expect(SettingsNavigation.orderedPanes == [
            .general, .appearance, .notifications, .keyboard,
            .connections, .profiles, .sidebar, .editor, .data,
            .ai, .mcp, .plugins,
            .sync, .account,
        ])
    }

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

    @Test("Sync is titled Sync, since it holds iCloud and TablePro Sync, and every pane has its own symbol")
    func titlesAndSymbols() {
        #expect(SettingsPane.sync.title == String(localized: "Sync"))
        #expect(SettingsPane.mcp.title == "MCP")
        let symbols = SettingsPane.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(SettingsPane.connections.symbol == "cylinder.split.1x2")
        #expect(SettingsPane.mcp.symbol == "point.3.connected.trianglepath.dotted")
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
        #expect(SettingsNavigation.panes(matching: " & ") == SettingsNavigation.orderedPanes)
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

    @Test("A term has to start a word, so date skips Update and count skips Account")
    func termsMatchWordPrefixes() {
        let date = SettingsNavigation.panes(matching: "date")
        #expect(date.contains(.data))
        #expect(!date.contains(.general))

        let count = SettingsNavigation.panes(matching: "count")
        #expect(count.contains(.data))
        #expect(!count.contains(.account))
    }

    private static let unitKeywordCases: [(String, [SettingsPane])] = [
        ("SQL Formatting", [.editor]),
        ("vim", [.editor]),
        ("line numbers", [.editor]),
        ("themes", [.appearance]),
        ("manage themes", [.appearance]),
        ("strip", [.sidebar]),
        ("default layout", [.sidebar]),
        ("view options", [.sidebar]),
        ("json", [.data]),
        ("password", [.profiles, .sync]),
        ("debugger", [.plugins]),
        ("long-running", [.notifications]),
        ("Sidebar & Tabs", [.sidebar]),
        ("Apple Intelligence", [.ai]),
    ]

    @Test("Each unit's keywords find their pane", arguments: unitKeywordCases)
    func unitKeywordsFindTheirPane(query: String, expected: [SettingsPane]) {
        #expect(SettingsNavigation.panes(matching: query) == expected)
    }

    @Test("A label the pane shows finds that pane or page")
    func visibleLabelsFindTheirPaneOrPage() {
        #expect(SettingsNavigation.panes(matching: "Saved Queries").contains(.sync))
        #expect(SettingsNavigation.panes(matching: "Approved connections").contains(.mcp))

        let connections = SettingsNavigation.results(matching: "Forget All").first { $0.pane == .connections }
        #expect(connections?.pages.contains { $0.location == SettingsLocation(page: .trustedLinks) } == true)
    }

    @Test("Backup does not find Sync, which keeps no backup")
    func backupDoesNotFindSync() {
        #expect(!SettingsNavigation.panes(matching: "backup").contains(.sync))
    }

    @Test("A page title lists the page under its pane")
    func pageTitlesProducePageResults() {
        let expected = SettingsSearchResult(
            pane: .appearance,
            pages: [.init(title: SettingsPage.manageThemes.title, location: SettingsLocation(page: .manageThemes))]
        )
        #expect(SettingsNavigation.results(matching: "manage themes") == [expected])

        let editor = SettingsNavigation.results(matching: "SQL Formatting")
        #expect(editor.first?.pages.map { $0.location } == [SettingsLocation(page: .sqlFormatting)])
    }

    @Test("A pane that matches only its keywords lists no pages")
    func paneKeywordMatchListsNoPages() {
        #expect(SettingsNavigation.results(matching: "vim") == [SettingsSearchResult(pane: .editor, pages: [])])
    }

    @Test("Every page is found by its title")
    func everyPageIsFoundByItsTitle() {
        for page in SettingsPage.allCases {
            let result = SettingsNavigation.results(matching: page.title).first { $0.pane == page.parent }
            #expect(result?.pages.contains { $0.location == SettingsLocation(page: page) } == true, "\(page)")
        }
    }

    @Test("Names only the app knows are searchable and open their page")
    func dynamicEntriesAreSearchable() {
        let provider = UUID()
        let entries = [
            SettingsSearchEntry(title: "PostgreSQL", location: SettingsLocation(route: .plugin(id: "com.tablepro.postgresql"))),
            SettingsSearchEntry(title: "Work Ollama", location: SettingsLocation(route: .aiProvider(provider))),
        ]

        let postgres = SettingsNavigation.results(matching: "postgres", adding: entries)
        #expect(postgres.map { $0.pane } == [.plugins])
        #expect(postgres.first?.pages.map { $0.title } == ["PostgreSQL"])

        let ollama = SettingsNavigation.results(matching: "work oll", adding: entries)
        #expect(ollama.map { $0.pane } == [.ai])
        #expect(ollama.first?.pages.map { $0.location } == [SettingsLocation(route: .aiProvider(provider))])

        #expect(SettingsNavigation.panes(matching: "postgres").isEmpty)
    }

    @Test("Matching ignores diacritics, case and width, and needs a word start")
    func vietnameseTitlesMatchWithoutDiacritics() {
        let index = SettingsSearchIndex(
            entries: [
                SettingsSearchEntry(title: "Giao diện", location: .root(.appearance)),
                SettingsSearchEntry(title: "Đồng bộ iCloud", location: .root(.sync)),
                SettingsSearchEntry(title: "Lịch sử truy vấn", location: SettingsLocation(page: .queryHistory)),
            ],
            locale: Locale(identifier: "vi")
        )
        #expect(index.results(matching: "giao dien").map { $0.pane } == [.appearance])
        #expect(index.results(matching: "GIAO DIỆN").map { $0.pane } == [.appearance])
        #expect(index.results(matching: "dien").map { $0.pane } == [.appearance])
        #expect(index.results(matching: "iao").isEmpty)
        #expect(index.results(matching: "dong bo").map { $0.pane } == [.sync])
        #expect(index.results(matching: "lich su").first?.pages.map { $0.location } == [SettingsLocation(page: .queryHistory)])
    }

    @Test("Each Han character starts a word")
    func hanCharactersStartWords() {
        let index = SettingsSearchIndex(entries: [SettingsSearchEntry(title: "外观设置", location: .root(.appearance))])
        #expect(index.results(matching: "设置").map { $0.pane } == [.appearance])
        #expect(index.results(matching: "外").map { $0.pane } == [.appearance])
    }

    @Test("Search results keep sidebar order")
    func searchResultsKeepSidebarOrder() {
        let results = SettingsNavigation.panes(matching: "e")
        let orderIndex = SettingsNavigation.orderedPanes.enumerated()
            .reduce(into: [SettingsPane: Int]()) { $0[$1.element] = $1.offset }
        let indices = results.compactMap { orderIndex[$0] }
        #expect(indices == indices.sorted())
    }

    @Test("Unfiltered rows are every pane with a spacer between sections")
    func unfilteredRowsHaveSpacers() {
        let rows = SettingsNavigation.rows(matching: "")
        let panes = rows.compactMap { row -> SettingsPane? in
            if case .pane(let pane) = row { return pane }
            return nil
        }
        #expect(panes == SettingsNavigation.orderedPanes)
        #expect(rows.filter { $0 == .spacer(before: .workspace) || $0 == .spacer(before: .integrations) || $0 == .spacer(before: .account) }.count == 3)
        #expect(rows.count == SettingsNavigation.orderedPanes.count + 3)
        #expect(rows.first == .pane(.general))
    }

    @Test("Filtered rows have no spacers and put each page under its pane")
    func filteredRowsListPagesUnderTheirPane() {
        let rows = SettingsNavigation.rows(matching: "manage themes")
        #expect(rows == [
            .pane(.appearance),
            .page(title: SettingsPage.manageThemes.title, location: SettingsLocation(page: .manageThemes)),
        ])
    }
}
