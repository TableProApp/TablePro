//
//  FilterPersistenceRoundTripTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// The reopen journey end to end: what a table's filter rows do between one tab and the next.
@Suite("FilterPersistenceRoundTrip", .serialized)
@MainActor
struct FilterPersistenceRoundTripTests {
    private static let settingsKey = "com.TablePro.filter.settings"

    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    @discardableResult
    private func addTableTab(to tabManager: QueryTabManager, tableName: String) -> UUID {
        var tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tab.tableContext.databaseName = ""
        tab.tableContext.isEditable = true
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    private func seedRows(_ coordinator: MainContentCoordinator, for tabId: UUID) {
        let columns = ["id", "status", "name"]
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let rows = (0..<3).map { index in columns.map { PluginCellValue.text("\($0)_\(index)") } }
        coordinator.setActiveTableRows(
            TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes),
            for: tabId
        )
    }

    private func withRestoreBehavior(_ behavior: FilterRestoreBehavior, _ body: () -> Void) {
        let defaults = AppStorageEnvironment.shared.defaults
        let previous = defaults.data(forKey: Self.settingsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: Self.settingsKey)
            } else {
                defaults.removeObject(forKey: Self.settingsKey)
            }
            FilterSettingsStorage.shared.saveSettings(
                previous.flatMap { try? JSONDecoder().decode(FilterSettings.self, from: $0) } ?? FilterSettings()
            )
        }
        FilterSettingsStorage.shared.saveSettings(FilterSettings(restoreBehavior: behavior))
        body()
    }

    private func save(
        _ state: PersistedFilterState,
        table: String,
        connectionId: UUID
    ) {
        FilterSettingsStorage.shared.saveLastFilters(
            state,
            for: table,
            connectionId: connectionId,
            databaseName: "",
            schemaName: nil
        )
    }

    private func saved(table: String, connectionId: UUID) -> PersistedFilterState {
        FilterSettingsStorage.shared.loadLastFilterState(
            for: table,
            connectionId: connectionId,
            databaseName: "",
            schemaName: nil
        )
    }

    private func clearSaved(table: String, connectionId: UUID) {
        FilterSettingsStorage.shared.clearLastFilters(
            for: table,
            connectionId: connectionId,
            databaseName: "",
            schemaName: nil
        )
    }

    @Test("Restore without applying reopens a table showing the filter over unfiltered rows")
    func restoreWithoutApplyingShowsTheRowsWithoutRunningThem() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { clearSaved(table: "users", connectionId: coordinator.connectionId) }
        let filter = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "5")
        save(
            PersistedFilterState(filters: [filter], isApplied: true),
            table: "users",
            connectionId: coordinator.connectionId
        )

        withRestoreBehavior(.restoreWithoutApplying) {
            let tabId = addTableTab(to: tabManager, tableName: "users")
            seedRows(coordinator, for: tabId)
            coordinator.restoreFiltersForSelectedTab()

            guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                Issue.record("Expected the tab to exist")
                return
            }
            #expect(tab.filterState.filters.map(\.id) == [filter.id])
            #expect(tab.filterState.isVisible)
            #expect(!tab.filterState.hasAppliedFilters)
            #expect(tab.filterState.executedFilters.isEmpty)
            #expect(!tab.content.query.uppercased().contains("WHERE"))
        }
    }

    @Test("Restore and apply reopens a table with the filter running")
    func restoreAndApplyRunsTheSavedFilter() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { clearSaved(table: "users", connectionId: coordinator.connectionId) }
        let filter = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "5")
        save(
            PersistedFilterState(filters: [filter], isApplied: true),
            table: "users",
            connectionId: coordinator.connectionId
        )

        withRestoreBehavior(.restoreAndApply) {
            let tabId = addTableTab(to: tabManager, tableName: "users")
            seedRows(coordinator, for: tabId)
            coordinator.restoreFiltersForSelectedTab()

            guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                Issue.record("Expected the tab to exist")
                return
            }
            #expect(tab.filterState.hasAppliedFilters)
            #expect(tab.content.query.uppercased().contains("WHERE"))
        }
    }

    /// The reporter's second half: rows typed into the panel and never applied used to be dropped,
    /// because saving an unapplied set wrote an empty one, which the storage reads as a delete.
    @Test("A row typed and never applied comes back on the next open")
    func anUnappliedDraftSurvivesReopen() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { clearSaved(table: "users", connectionId: coordinator.connectionId) }

        withRestoreBehavior(.restoreAndApply) {
            let tabId = addTableTab(to: tabManager, tableName: "users")
            guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                Issue.record("Expected the tab to exist")
                return
            }
            let draft = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "5")
            tabManager.tabs[index].filterState.filters = [draft]
            tabManager.tabs[index].filterState.commit = nil

            coordinator.saveLastFilters(of: tabManager.tabs[index])

            let state = saved(table: "users", connectionId: coordinator.connectionId)
            #expect(state.filters.map(\.id) == [draft.id])
            #expect(!state.isApplied)

            tabManager.tabs[index].filterState = TabFilterState()
            coordinator.restoreFiltersForSelectedTab()

            #expect(tabManager.tabs[index].filterState.filters.map(\.id) == [draft.id])
            #expect(!tabManager.tabs[index].filterState.hasAppliedFilters)
        }
    }

    /// Closing the tab removes it before the selection moves, so the tab-switch save never sees it.
    @Test("Closing a tab saves the rows left in its filter bar")
    func closingATabSavesItsDraft() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { clearSaved(table: "users", connectionId: coordinator.connectionId) }

        withRestoreBehavior(.restoreAndApply) {
            let usersId = addTableTab(to: tabManager, tableName: "users")
            addTableTab(to: tabManager, tableName: "orders")
            guard let index = tabManager.tabs.firstIndex(where: { $0.id == usersId }) else {
                Issue.record("Expected the users tab to exist")
                return
            }
            let draft = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "5")
            tabManager.tabs[index].filterState.filters = [draft]
            tabManager.tabs[index].filterState.commit = nil

            coordinator.closeTabsByUser(ids: [usersId])

            let state = saved(table: "users", connectionId: coordinator.connectionId)
            #expect(state.filters.map(\.id) == [draft.id])
            #expect(!state.isApplied)
        }
    }

    /// A restored session hands back several table tabs. Loading only the selected one left the
    /// others holding an empty set, which the next tab switch saved over their filters.
    @Test("A tab that is not selected restores its own filters")
    func aBackgroundTabRestoresItsOwnFilters() {
        let (coordinator, tabManager) = makeCoordinator()
        defer {
            clearSaved(table: "users", connectionId: coordinator.connectionId)
            clearSaved(table: "orders", connectionId: coordinator.connectionId)
        }
        let orderFilter = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "open")
        save(
            PersistedFilterState(filters: [orderFilter], isApplied: true),
            table: "orders",
            connectionId: coordinator.connectionId
        )

        withRestoreBehavior(.restoreAndApply) {
            let ordersId = addTableTab(to: tabManager, tableName: "orders")
            addTableTab(to: tabManager, tableName: "users")

            for index in tabManager.tabs.indices {
                coordinator.restoreFilters(forTabAt: index)
            }

            guard let orders = tabManager.tabs.first(where: { $0.id == ordersId }) else {
                Issue.record("Expected the orders tab to exist")
                return
            }
            #expect(orders.filterState.filters.map(\.id) == [orderFilter.id])
            #expect(orders.filterState.hasAppliedFilters)
        }
    }

    /// The query a restored tab carries is the last filtered SQL it ran. Bringing the filter back
    /// unapplied without rebuilding would keep running that WHERE while the panel reported nothing.
    @Test("Restoring without applying drops a stale WHERE from the tab's query")
    func restoringWithoutApplyingRebuildsTheQuery() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { clearSaved(table: "users", connectionId: coordinator.connectionId) }
        let filter = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "5")
        save(
            PersistedFilterState(filters: [filter], isApplied: true),
            table: "users",
            connectionId: coordinator.connectionId
        )

        withRestoreBehavior(.restoreWithoutApplying) {
            let tabId = addTableTab(to: tabManager, tableName: "users")
            guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                Issue.record("Expected the tab to exist")
                return
            }
            seedRows(coordinator, for: tabId)
            tabManager.tabs[index].content.query = "SELECT * FROM users WHERE id = '5'"

            coordinator.restoreFiltersForSelectedTab()

            #expect(!tabManager.tabs[index].content.query.uppercased().contains("WHERE"))
        }
    }

    /// Turning saving off has to leave what is on disk alone, or the option could never be
    /// turned back on.
    @Test("Don't save neither reads nor deletes the filters already on disk")
    func dontSaveLeavesTheFileAlone() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { clearSaved(table: "users", connectionId: coordinator.connectionId) }
        let filter = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "5")
        save(
            PersistedFilterState(filters: [filter], isApplied: true),
            table: "users",
            connectionId: coordinator.connectionId
        )

        withRestoreBehavior(.dontSave) {
            let tabId = addTableTab(to: tabManager, tableName: "users")
            coordinator.restoreFiltersForSelectedTab()

            guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                Issue.record("Expected the tab to exist")
                return
            }
            #expect(tabManager.tabs[index].filterState.filters.isEmpty)

            coordinator.saveLastFilters(of: tabManager.tabs[index])
            FilterSettingsStorage.shared.waitForPendingDiskWrites()
        }

        #expect(saved(table: "users", connectionId: coordinator.connectionId).filters.map(\.id) == [filter.id])
    }
}
