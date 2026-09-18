import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Filter values are typed from the schema before a table's first rows load")
@MainActor
struct FilterTypingBeforeFirstLoadTests {
    private static let schema = SchemaColumnStore.Entry(
        columns: ["id", "code"],
        primaryKeys: ["id"],
        columnTypes: ["id": .integer(rawType: "INT"), "code": .text(rawType: "VARCHAR(20)")]
    )

    private func makeCoordinator(
        filter: TableFilter
    ) -> (coordinator: MainContentCoordinator, tabManager: QueryTabManager, tabId: UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "items", query: "SELECT * FROM `items` LIMIT 200", tabType: .table)
        tab.tableContext.tableName = "items"
        tab.filterState = TabFilterState(filters: [filter], commit: .all, isVisible: true, filterLogicMode: .and)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return (coordinator, tabManager, tab.id)
    }

    private func storeSchema(in coordinator: MainContentCoordinator) {
        coordinator.schemaColumns.store(
            Self.schema,
            for: coordinator.schemaColumnsKey("items", scope: coordinator.selectedTabScope)
        )
    }

    private func firstLoadQuery(
        _ coordinator: MainContentCoordinator,
        _ tabManager: QueryTabManager,
        tabId: UUID
    ) async -> String? {
        let previous = AppSettingsManager.shared.dataGrid.defaultSortBehavior
        AppSettingsManager.shared.dataGrid.defaultSortBehavior = .none
        defer { AppSettingsManager.shared.dataGrid.defaultSortBehavior = previous }

        guard await coordinator.prepareTableTabFirstLoad(tabId: tabId) else { return nil }
        return tabManager.tabs.first { $0.id == tabId }?.content.query
    }

    @Test("A numeric-looking value on a text column is quoted in the first query")
    func textColumnValueIsQuotedOnFirstLoad() async throws {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            filter: TestFixtures.makeTableFilter(column: "code", value: "0123")
        )
        defer { coordinator.teardown() }
        storeSchema(in: coordinator)

        let query = try #require(await firstLoadQuery(coordinator, tabManager, tabId: tabId))

        #expect(query.contains("'0123'"))
        #expect(!query.contains("= 0123"))
    }

    @Test("A numeric value on an integer column stays unquoted in the first query")
    func integerColumnValueStaysUnquotedOnFirstLoad() async throws {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            filter: TestFixtures.makeTableFilter(column: "id", value: "123")
        )
        defer { coordinator.teardown() }
        storeSchema(in: coordinator)

        let query = try #require(await firstLoadQuery(coordinator, tabManager, tabId: tabId))

        #expect(query.contains("`id` = 123"))
        #expect(!query.contains("'123'"))
    }

    @Test("A TRUE value on a text column is not rewritten into a boolean literal")
    func textColumnKeepsBooleanShapedValue() async throws {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            filter: TestFixtures.makeTableFilter(column: "code", value: "TRUE")
        )
        defer { coordinator.teardown() }
        storeSchema(in: coordinator)

        let query = try #require(await firstLoadQuery(coordinator, tabManager, tabId: tabId))

        #expect(query.contains("'TRUE'"))
    }

    @Test("A schema that cannot be fetched still dispatches the first load")
    func unavailableSchemaStillDispatches() async throws {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            filter: TestFixtures.makeTableFilter(column: "code", value: "0123")
        )
        defer { coordinator.teardown() }

        let query = try #require(await firstLoadQuery(coordinator, tabManager, tabId: tabId))

        #expect(query.contains("WHERE"))
    }

    @Test("Applied filters make the first load wait for the schema")
    func appliedFiltersNeedTheSchema() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            filter: TestFixtures.makeTableFilter(column: "code", value: "0123")
        )
        defer { coordinator.teardown() }
        let previous = AppSettingsManager.shared.dataGrid.defaultSortBehavior
        AppSettingsManager.shared.dataGrid.defaultSortBehavior = .none
        defer { AppSettingsManager.shared.dataGrid.defaultSortBehavior = previous }

        let filtered = tabManager.tabs.first { $0.id == tabId }
        var unfiltered = filtered
        unfiltered?.filterState = TabFilterState()

        #expect(filtered.map { coordinator.firstLoadNeedsSchemaColumns(for: $0, hint: .useAppDefault) } == true)
        #expect(unfiltered.map { coordinator.firstLoadNeedsSchemaColumns(for: $0, hint: .useAppDefault) } == false)
    }

    @Test("The filter preview is typed from the schema before any rows arrive")
    func previewIsTypedBeforeRowsArrive() {
        let (coordinator, _, _) = makeCoordinator(
            filter: TestFixtures.makeTableFilter(column: "code", value: "0123")
        )
        defer { coordinator.teardown() }
        storeSchema(in: coordinator)

        let preview = coordinator.filterCoordinator.generateFilterPreviewSQL(databaseType: .mysql)

        #expect(preview.contains("'0123'"))
    }

    @Test("Loaded rows decide the types once they exist")
    func loadedRowsWinOverTheSchema() throws {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            filter: TestFixtures.makeTableFilter(column: "code", value: "0123")
        )
        defer { coordinator.teardown() }
        storeSchema(in: coordinator)
        coordinator.setActiveTableRows(
            TableRows.from(queryRows: [], columns: ["code"], columnTypes: [.integer(rawType: "INT")]),
            for: tabId
        )

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        let resolved = coordinator.queryColumns(for: tab)

        #expect(resolved.columns == ["code"])
        #expect(resolved.columnTypes == [.integer(rawType: "INT")])
    }

    @Test("Before any rows the schema supplies a type for every query column")
    func schemaSuppliesTypesBeforeRows() throws {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            filter: TestFixtures.makeTableFilter(column: "code", value: "0123")
        )
        defer { coordinator.teardown() }
        storeSchema(in: coordinator)

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        let resolved = coordinator.queryColumns(for: tab)

        #expect(resolved.columns == ["id", "code"])
        #expect(resolved.columnTypes == [.integer(rawType: "INT"), .text(rawType: "VARCHAR(20)")])
    }
}
