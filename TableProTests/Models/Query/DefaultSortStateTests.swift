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

@Suite("A user-cleared sort is distinguishable from a tab that has not sorted")
@MainActor
struct UserClearedSortIsDistinctTests {
    @Test("A fresh sort state is unset, not user")
    func freshStateIsUnset() {
        #expect(SortState().source == .unset)
    }

    @Test("Don't Sort round-trips through persistence as the user's own empty sort")
    func dontSortSurvivesPersistence() throws {
        var tab = QueryTab(title: "users", query: "SELECT 1", tabType: .table)
        tab.tableContext.tableName = "users"
        tab.sortState = SortState(columns: [], source: .user)

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)

        #expect(restored.sortState.source == .user)
        #expect(!restored.sortState.isSorting)
    }

    @Test("A tab that never sorted round-trips as unset")
    func neverSortedRoundTripsUnset() throws {
        var tab = QueryTab(title: "users", query: "SELECT 1", tabType: .table)
        tab.tableContext.tableName = "users"

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)

        #expect(restored.sortState.source == .unset)
    }

    @Test("A file written before sortSource existed decodes to what it was written under")
    func legacyFileDecodesToPriorBehaviour() throws {
        var sorted = QueryTab(title: "users", query: "SELECT 1", tabType: .table)
        sorted.tableContext.tableName = "users"
        sorted.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending, columnName: "id")],
            source: .user
        )

        /// The shape a shipped build wrote: the same record with the key absent entirely.
        let legacy = try stripping("sortSource", from: sorted.toPersistedTab())
        #expect(legacy.sortSource == nil)
        #expect(legacy.sortColumns?.isEmpty == false)
        #expect(QueryTab(from: legacy, defaultPageSize: 1_000).restoredSortSource == .user)

        var unsorted = QueryTab(title: "logs", query: "SELECT 1", tabType: .table)
        unsorted.tableContext.tableName = "logs"
        let legacyUnsorted = try stripping("sortSource", from: unsorted.toPersistedTab())
        #expect(QueryTab(from: legacyUnsorted, defaultPageSize: 1_000).restoredSortSource == .unset)
    }

    private func stripping(_ key: String, from tab: PersistedTab) throws -> PersistedTab {
        let encoded = try JSONEncoder().encode(tab)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("PersistedTab did not encode as a JSON object")
            return tab
        }
        object.removeValue(forKey: key)
        let stripped = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PersistedTab.self, from: stripped)
    }
}

@Suite("QueryTabManager.replaceTabContent resets sort state")
@MainActor
struct ReplaceTabContentDefaultSortResetTests {
    @Test("replaceTabContent clears sortState back to unset, so the new table gets the app default")
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
        #expect(manager.tabs[index].sortState.source == .unset)
    }
}

@Suite("DataGridSettings.defaultSortBehavior decoder")
struct DataGridSettingsDefaultSortDecoderTests {
    @Test("Missing direction key falls back to ascending, so a shipped user sees no change")
    func missingDirectionFallsBackToAscending() throws {
        let legacyJSON = """
        {
            "defaultSortBehavior": "primaryKey"
        }
        """

        let settings = try JSONDecoder().decode(DataGridSettings.self, from: Data(legacyJSON.utf8))

        #expect(settings.defaultSortDirection == .ascending)
    }

    @Test("Explicit descending direction round-trips")
    func descendingDirectionRoundTrips() throws {
        var settings = DataGridSettings.default
        settings.defaultSortDirection = .descending

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: data)

        #expect(decoded.defaultSortDirection == .descending)
    }

    @Test("Missing key falls back to .none for upgrading users")
    func missingKeyFallsBackToNone() throws {
        let legacyJSON = """
        {
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
