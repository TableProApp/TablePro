import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("QueryTab.hasUserActiveSort")
@MainActor
struct QueryTabHasUserActiveSortTests {
    @Test("Empty sortState is not user-active")
    func emptyStateNotActive() {
        var tab = QueryTab(tabType: .table)
        tab.sortState = SortState()
        #expect(!tab.hasUserActiveSort)
    }

    @Test("Default-sourced sortState is not user-active")
    func defaultSourceNotActive() {
        var tab = QueryTab(tabType: .table)
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending)],
            source: .defaultSort
        )
        #expect(tab.sortState.isSorting)
        #expect(!tab.hasUserActiveSort)
    }

    @Test("User-sourced sortState with columns is user-active")
    func userSourceIsActive() {
        var tab = QueryTab(tabType: .table)
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 1, direction: .descending)],
            source: .user
        )
        #expect(tab.hasUserActiveSort)
    }

    @Test("User-cleared (empty + user source) is not active")
    func userClearedNotActive() {
        var tab = QueryTab(tabType: .table)
        tab.sortState = SortState(columns: [], source: .user)
        #expect(!tab.hasUserActiveSort)
    }
}

@Suite("QueryTabManager.replaceTabContent resets sort state")
@MainActor
struct ReplaceTabContentDefaultSortResetTests {
    @Test("replaceTabContent clears sortState (back to .user default)")
    func replaceClearsSortState() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        guard let index = manager.selectedTabIndex else {
            Issue.record("selectedTabIndex was nil after addTableTab")
            return
        }
        manager.mutate(at: index) { tab in
            tab.sortState = SortState(
                columns: [SortColumn(columnIndex: 0, direction: .ascending)],
                source: .defaultSort
            )
        }
        #expect(manager.tabs[index].sortState.isSorting)

        try manager.replaceTabContent(tableName: "orders")

        #expect(!manager.tabs[index].sortState.isSorting)
        #expect(manager.tabs[index].sortState.source == .user)
    }
}

@Suite("DataGridSettings.defaultSortBehavior decoder")
struct DataGridSettingsDefaultSortDecoderTests {
    @Test("Missing key falls back to .none for upgrading users")
    func missingKeyFallsBackToNone() throws {
        let legacyJSON = """
        {
            "rowHeight": "normal",
            "dateFormat": "yyyy-MM-dd HH:mm:ss",
            "nullDisplay": "NULL",
            "defaultPageSize": 1000,
            "showAlternateRows": true,
            "showRowNumbers": true,
            "autoShowInspector": false,
            "enableSmartValueDetection": true,
            "countRowsIfEstimateLessThan": 100000,
            "queryResultRowCap": 10000,
            "truncateQueryResults": true
        }
        """

        let settings = try JSONDecoder().decode(DataGridSettings.self, from: Data(legacyJSON.utf8))

        #expect(settings.defaultSortBehavior == .none)
    }

    @Test("Explicit primaryKey value round-trips")
    func explicitPrimaryKeyRoundTrips() throws {
        var settings = DataGridSettings.default
        settings.defaultSortBehavior = .primaryKey

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: data)

        #expect(decoded.defaultSortBehavior == .primaryKey)
    }
}
