//
//  FilterPersistenceRoundTripTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct FilterPersistenceRoundTripTests {
    private let fixtures = CoordinatorFixtures()

    private static let settingsKey = "com.TablePro.filter.settings"

    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let fixture = fixtures.make()
        let tabManager = fixture.tabManager
        let coordinator = fixture.coordinator
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
            #expect(tab.filterState.applied == nil)
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
            #expect(tab.filterState.isFiltering)
            #expect(tab.content.query.uppercased().contains("WHERE"))
        }
    }

    @Test("A row applied alone reopens applied alone, not as the checked rows")
    func aRowAppliedAloneSurvivesReopen() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { clearSaved(table: "users", connectionId: coordinator.connectionId) }

        withRestoreBehavior(.restoreAndApply) {
            let tabId = addTableTab(to: tabManager, tableName: "users")
            seedRows(coordinator, for: tabId)
            guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                Issue.record("Expected the tab to exist")
                return
            }
            let checked = TestFixtures.makeTableFilter(column: "status", op: .equal, value: "checked-row")
            let alone = TestFixtures.makeTableFilter(column: "name", op: .equal, value: "alone-row", isEnabled: false)
            tabManager.tabs[index].filterState.filters = [checked, alone]
            coordinator.filterCoordinator.applyFilterAlone(alone.id)

            tabManager.tabs[index].filterState = TabFilterState()
            tabManager.tabs[index].content.query = "SELECT * FROM users"
            coordinator.restoreFiltersForSelectedTab()

            let restored = tabManager.tabs[index]
            #expect(restored.filterState.filters.map(\.id) == [checked.id, alone.id])
            #expect(restored.filterState.filters.map(\.isEnabled) == [true, false])
            #expect(restored.filterState.aloneFilterID == alone.id)
            #expect(restored.content.query.contains("alone-row"))
            #expect(!restored.content.query.contains("checked-row"))
        }
    }

    // Saving an unapplied set once wrote an empty one, which the storage reads as a delete.
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
            tabManager.tabs[index].filterState.applied = nil

            coordinator.saveLastFilters(of: tabManager.tabs[index])

            let state = saved(table: "users", connectionId: coordinator.connectionId)
            #expect(state.filters.map(\.id) == [draft.id])
            #expect(!state.isApplied)

            tabManager.tabs[index].filterState = TabFilterState()
            coordinator.restoreFiltersForSelectedTab()

            #expect(tabManager.tabs[index].filterState.filters.map(\.id) == [draft.id])
            #expect(!tabManager.tabs[index].filterState.isFiltering)
        }
    }

    // Closing the tab removes it before the selection moves, so the tab-switch save never sees it.
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
            tabManager.tabs[index].filterState.applied = nil

            coordinator.closeTabsByUser(ids: [usersId])

            let state = saved(table: "users", connectionId: coordinator.connectionId)
            #expect(state.filters.map(\.id) == [draft.id])
            #expect(!state.isApplied)
        }
    }

    // Loading only the selected tab left the others empty, and the next tab switch saved that over their filters.
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
            #expect(orders.filterState.isFiltering)
        }
    }

    // A restored tab carries the last filtered SQL it ran, which would keep running while the panel showed nothing.
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

    // Turning saving off has to leave what is on disk alone, or the option could never be turned back on.
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
