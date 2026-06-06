import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Default sort resolves before the first table result loads")
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

    private func schemaCacheKey(_ coordinator: MainContentCoordinator, table: String, schema: String? = nil) -> String {
        "\(coordinator.connectionId):\(coordinator.activeDatabaseName):\(schema ?? ""):\(table)"
    }

    @Test("rebuildTableQuery emits ORDER BY from schema columns before any rows load")
    func sortsFromSchemaColumnsBeforeFirstResult() {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        coordinator.schemaColumnsCache[schemaCacheKey(coordinator, table: "users")] = (["id", "name", "email"], ["id"])

        tabManager.mutate(at: index) {
            $0.sortState = SortState(
                columns: [SortColumn(columnIndex: 0, direction: .ascending)],
                source: .defaultSort
            )
        }

        coordinator.filterCoordinator.rebuildTableQuery(at: index)

        let query = tabManager.tabs[index].content.query
        #expect(query.localizedCaseInsensitiveContains("ORDER BY"))
        #expect(query.contains("id"))
    }

    @Test("Default sort resolves against scoped columns when leading columns are hidden")
    func sortsAgainstScopedColumnsWithHiddenColumns() {
        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        coordinator.schemaColumnsCache[schemaCacheKey(coordinator, table: "users")] = (["a", "id", "name"], ["id"])
        tabManager.mutate(at: index) { $0.columnLayout.hiddenColumns = ["a"] }

        let resultColumns = coordinator.effectiveResultColumns(for: tabManager.tabs[index])
        #expect(resultColumns == ["id", "name"])

        let resolved = DefaultSortResolver.resolveSortState(
            behavior: .primaryKey,
            pluginHint: .useAppDefault,
            primaryKeyColumns: ["id"],
            allColumns: resultColumns
        )
        #expect(resolved.columns.first?.columnIndex == 0)

        tabManager.mutate(at: index) { $0.sortState = resolved }
        coordinator.filterCoordinator.rebuildTableQuery(at: index)

        let query = tabManager.tabs[index].content.query
        #expect(query.localizedCaseInsensitiveContains("ORDER BY"))
        #expect(query.contains("id"))
        #expect(!query.contains("`a`"))
    }

    @Test("shouldResolveDefaultSort is true for a fresh table tab when the default sort is primary key")
    func gateTrueForPrimaryKeyBehavior() {
        let previous = AppSettingsManager.shared.dataGrid.defaultSortBehavior
        AppSettingsManager.shared.dataGrid.defaultSortBehavior = .primaryKey
        defer { AppSettingsManager.shared.dataGrid.defaultSortBehavior = previous }

        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        #expect(coordinator.shouldResolveDefaultSort(for: tabManager.tabs[index]))
    }

    @Test("shouldResolveDefaultSort is false once the gate has been evaluated")
    func gateFalseAfterEvaluation() {
        let previous = AppSettingsManager.shared.dataGrid.defaultSortBehavior
        AppSettingsManager.shared.dataGrid.defaultSortBehavior = .primaryKey
        defer { AppSettingsManager.shared.dataGrid.defaultSortBehavior = previous }

        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        tabManager.mutate(at: index) { $0.execution.didEvaluateDefaultSort = true }
        #expect(!coordinator.shouldResolveDefaultSort(for: tabManager.tabs[index]))
    }

    @Test("shouldResolveDefaultSort is false when the user already sorted")
    func gateFalseWhenUserSorting() {
        let previous = AppSettingsManager.shared.dataGrid.defaultSortBehavior
        AppSettingsManager.shared.dataGrid.defaultSortBehavior = .primaryKey
        defer { AppSettingsManager.shared.dataGrid.defaultSortBehavior = previous }

        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        tabManager.mutate(at: index) {
            $0.sortState = SortState(columns: [SortColumn(columnIndex: 1, direction: .descending)], source: .user)
        }
        #expect(!coordinator.shouldResolveDefaultSort(for: tabManager.tabs[index]))
    }

    @Test("shouldResolveDefaultSort is false when the default sort behavior is none")
    func gateFalseForNoneBehavior() {
        let previous = AppSettingsManager.shared.dataGrid.defaultSortBehavior
        AppSettingsManager.shared.dataGrid.defaultSortBehavior = .none
        defer { AppSettingsManager.shared.dataGrid.defaultSortBehavior = previous }

        let (coordinator, tabManager, index) = makeCoordinator(tableName: "users")
        #expect(!coordinator.shouldResolveDefaultSort(for: tabManager.tabs[index]))
    }

    @Test("shouldResolveDefaultSort is false for non-table tabs")
    func gateFalseForQueryTab() {
        let previous = AppSettingsManager.shared.dataGrid.defaultSortBehavior
        AppSettingsManager.shared.dataGrid.defaultSortBehavior = .primaryKey
        defer { AppSettingsManager.shared.dataGrid.defaultSortBehavior = previous }

        let (coordinator, _, _) = makeCoordinator(tableName: "users")
        let queryTab = QueryTab(title: "Q", query: "SELECT 1", tabType: .query)
        #expect(!coordinator.shouldResolveDefaultSort(for: queryTab))
    }
}
