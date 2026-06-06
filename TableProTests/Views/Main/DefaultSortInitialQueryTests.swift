import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Default sort resolves before the first table query is dispatched")
@MainActor
struct DefaultSortInitialQueryTests {
    private func makeCoordinator(tableName: String) -> (MainContentCoordinator, QueryTabManager, Int) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: tableName, query: "SELECT * FROM `\(tableName)` LIMIT 200", tabType: .table)
        tab.tableContext.tableName = tableName
        tab.tableContext.isEditable = true
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return (coordinator, tabManager, tabManager.tabs.count - 1)
    }

    private func withDefaultSortBehavior(
        _ behavior: DefaultSortBehavior,
        body: () async -> Void
    ) async {
        let previous = AppSettingsManager.shared.dataGrid.defaultSortBehavior
        AppSettingsManager.shared.dataGrid.defaultSortBehavior = behavior
        defer { AppSettingsManager.shared.dataGrid.defaultSortBehavior = previous }
        await body()
    }

    @Test("prepareTableTabFirstLoad bakes the primary key ORDER BY into the first query")
    func firstQueryContainsPrimaryKeyOrderBy() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        coordinator.schemaColumns.store(
            (columns: ["id", "name", "email"], primaryKeys: ["id"]),
            for: coordinator.schemaColumnsKey("users", schema: nil)
        )

        await withDefaultSortBehavior(.primaryKey) {
            let ready = await coordinator.prepareTableTabFirstLoad(tabId: tabManager.tabs[index].id)
            #expect(ready)
        }

        let query = tabManager.tabs[index].content.query
        #expect(query.localizedCaseInsensitiveContains("ORDER BY"))
        #expect(query.contains("id"))
        #expect(tabManager.tabs[index].sortState.source == .defaultSort)
    }

    @Test("Composite primary key sorts by every key column in key order")
    func compositePrimaryKeySortsAllKeyColumns() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "invoices")
        coordinator.schemaColumns.store(
            (columns: ["customer_uid", "order_uid", "total"], primaryKeys: ["customer_uid", "order_uid"]),
            for: coordinator.schemaColumnsKey("invoices", schema: nil)
        )

        await withDefaultSortBehavior(.primaryKey) {
            await coordinator.prepareTableTabFirstLoad(tabId: tabManager.tabs[index].id)
        }

        let sortState = tabManager.tabs[index].sortState
        #expect(sortState.columns.map(\.columnIndex) == [0, 1])
        let query = tabManager.tabs[index].content.query
        #expect(query.localizedCaseInsensitiveContains("ORDER BY"))
        #expect(query.contains("customer_uid"))
        #expect(query.contains("order_uid"))
    }

    @Test("Table without a primary key dispatches unsorted with no ORDER BY")
    func noPrimaryKeyProducesNoOrderBy() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "logs")
        coordinator.schemaColumns.store(
            (columns: ["message", "level"], primaryKeys: []),
            for: coordinator.schemaColumnsKey("logs", schema: nil)
        )
        let originalQuery = tabManager.tabs[index].content.query

        await withDefaultSortBehavior(.primaryKey) {
            let ready = await coordinator.prepareTableTabFirstLoad(tabId: tabManager.tabs[index].id)
            #expect(ready)
        }

        #expect(tabManager.tabs[index].content.query == originalQuery)
        #expect(!tabManager.tabs[index].sortState.isSorting)
    }

    @Test("Schema fetch failure dispatches unsorted instead of blocking the first load")
    func schemaFetchFailureStillDispatches() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        let originalQuery = tabManager.tabs[index].content.query

        await withDefaultSortBehavior(.primaryKey) {
            let ready = await coordinator.prepareTableTabFirstLoad(tabId: tabManager.tabs[index].id)
            #expect(ready)
        }

        #expect(tabManager.tabs[index].content.query == originalQuery)
    }

    @Test("None behavior takes the fast path without touching the query")
    func noneBehaviorSkipsSchemaWait() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        let originalQuery = tabManager.tabs[index].content.query

        await withDefaultSortBehavior(DefaultSortBehavior.none) {
            let ready = await coordinator.prepareTableTabFirstLoad(tabId: tabManager.tabs[index].id)
            #expect(ready)
        }

        #expect(tabManager.tabs[index].content.query == originalQuery)
        #expect(!tabManager.tabs[index].sortState.isSorting)
    }

    @Test("A restored user sort is never overwritten by the default sort")
    func userSortSurvivesFirstLoad() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        coordinator.schemaColumns.store(
            (columns: ["id", "name"], primaryKeys: ["id"]),
            for: coordinator.schemaColumnsKey("users", schema: nil)
        )
        let userSort = SortState(columns: [SortColumn(columnIndex: 1, direction: .descending)], source: .user)
        tabManager.mutate(at: index) { $0.sortState = userSort }

        await withDefaultSortBehavior(.primaryKey) {
            await coordinator.prepareTableTabFirstLoad(tabId: tabManager.tabs[index].id)
        }

        #expect(tabManager.tabs[index].sortState == userSort)
    }

    @Test("Default sort resolves against scoped columns when leading columns are hidden")
    func sortsAgainstScopedColumnsWithHiddenColumns() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        coordinator.schemaColumns.store(
            (columns: ["a", "id", "name"], primaryKeys: ["id"]),
            for: coordinator.schemaColumnsKey("users", schema: nil)
        )
        tabManager.mutate(at: index) { $0.columnLayout.hiddenColumns = ["a"] }

        let resultColumns = coordinator.effectiveResultColumns(for: tabManager.tabs[index])
        #expect(resultColumns == ["id", "name"])

        await withDefaultSortBehavior(.primaryKey) {
            await coordinator.prepareTableTabFirstLoad(tabId: tabManager.tabs[index].id)
        }

        let query = tabManager.tabs[index].content.query
        #expect(query.localizedCaseInsensitiveContains("ORDER BY"))
        #expect(query.contains("id"))
        #expect(!query.contains("`a`"))
    }

    @Test("prepareTableTabFirstLoad bails when the tab is no longer selected")
    func bailsWhenTabDeselected() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        let tabId = tabManager.tabs[index].id
        tabManager.selectedTabId = nil

        await withDefaultSortBehavior(.primaryKey) {
            let ready = await coordinator.prepareTableTabFirstLoad(tabId: tabId)
            #expect(!ready)
        }
    }

    @Test("wantsDefaultSort is true for a fresh table tab when the default sort is primary key")
    func gateTrueForPrimaryKeyBehavior() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        await withDefaultSortBehavior(.primaryKey) {
            #expect(coordinator.wantsDefaultSort(for: tabManager.tabs[index], hint: .useAppDefault))
        }
    }

    @Test("wantsDefaultSort is false when the user already sorted")
    func gateFalseWhenUserSorting() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        tabManager.mutate(at: index) {
            $0.sortState = SortState(columns: [SortColumn(columnIndex: 1, direction: .descending)], source: .user)
        }
        await withDefaultSortBehavior(.primaryKey) {
            #expect(!coordinator.wantsDefaultSort(for: tabManager.tabs[index], hint: .useAppDefault))
        }
    }

    @Test("wantsDefaultSort is false when the default sort behavior is none")
    func gateFalseForNoneBehavior() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        await withDefaultSortBehavior(DefaultSortBehavior.none) {
            #expect(!coordinator.wantsDefaultSort(for: tabManager.tabs[index], hint: .useAppDefault))
        }
    }

    @Test("wantsDefaultSort is false for non-table tabs")
    func gateFalseForQueryTab() async {
        let (coordinator, _, _) = makeCoordinator(tableName: "users")
        let queryTab = QueryTab(title: "Q", query: "SELECT 1", tabType: .query)
        await withDefaultSortBehavior(.primaryKey) {
            #expect(!coordinator.wantsDefaultSort(for: queryTab, hint: .useAppDefault))
        }
    }

    @Test("wantsDefaultSort is false when the plugin suppresses default sorting")
    func gateFalseForSuppressHint() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        await withDefaultSortBehavior(.primaryKey) {
            #expect(!coordinator.wantsDefaultSort(for: tabManager.tabs[index], hint: .suppress))
        }
    }

    @Test("wantsDefaultSort is true when the plugin forces sort columns even with behavior none")
    func gateTrueForForceColumnsHint() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        await withDefaultSortBehavior(DefaultSortBehavior.none) {
            #expect(coordinator.wantsDefaultSort(for: tabManager.tabs[index], hint: .forceColumns(["id"])))
        }
    }

    @Test("None behavior skips the schema wait unless columns are hidden")
    func firstLoadSchemaWaitDecision() async {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")

        await withDefaultSortBehavior(DefaultSortBehavior.none) {
            #expect(!coordinator.firstLoadNeedsSchemaColumns(for: tabManager.tabs[index], hint: .useAppDefault))
        }

        await withDefaultSortBehavior(.primaryKey) {
            #expect(coordinator.firstLoadNeedsSchemaColumns(for: tabManager.tabs[index], hint: .useAppDefault))
        }

        tabManager.mutate(at: index) { $0.columnLayout.hiddenColumns = ["name"] }
        await withDefaultSortBehavior(DefaultSortBehavior.none) {
            #expect(coordinator.firstLoadNeedsSchemaColumns(for: tabManager.tabs[index], hint: .useAppDefault))
        }
    }
}
