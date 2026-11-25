//
//  FilterRerunTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

// A page turn, sort or refresh rebuilds the query from `applied`; the panel's draft runs only once applied.
@MainActor
struct FilterRerunTests {
    private func makeTableCoordinator(
        _ filters: [TableFilter],
        type: DatabaseType = .postgresql
    ) -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: type),
            tabManager: tabManager,
            toolbarState: ConnectionToolbarState()
        )
        tabManager.tabs.append(makeTab(table: "users", filters: filters))
        tabManager.selectedTabId = tabManager.tabs[0].id
        return (coordinator, tabManager)
    }

    private func makeTab(table: String, schema: String? = nil, filters: [TableFilter]) -> QueryTab {
        var tab = QueryTab(title: table, query: "SELECT * FROM \(table)", tabType: .table)
        tab.tableContext.tableName = table
        tab.tableContext.schemaName = schema
        tab.filterState.filters = filters
        tab.filterState.applied = .checkedRows(of: filters, logicMode: .and)
        return tab
    }

    private func column(_ name: String) -> EditableColumnDefinition {
        var column = EditableColumnDefinition.placeholder()
        column.name = name
        column.dataType = "text"
        return column
    }

    private func clearSavedFilters(_ coordinator: MainContentCoordinator, table: String = "users", schema: String? = nil) {
        FilterSettingsStorage.shared.clearLastFilters(
            for: table,
            connectionId: coordinator.connectionId,
            databaseName: "",
            schemaName: schema
        )
    }

    @Test("A rebuild reruns what ran, not a row edited after Apply")
    func rebuildIgnoresUnappliedEdit() {
        let (coordinator, tabManager) = makeTableCoordinator([TableFilter(columnName: "name", value: "bob")])
        coordinator.rebuildTableQuery(at: 0)
        #expect(tabManager.tabs[0].content.query.contains("'bob'"))

        tabManager.mutate(at: 0) {
            $0.filterState.filters[0] = $0.filterState.filters[0].selectingRawCondition()
        }
        coordinator.rebuildTableQuery(at: 0)

        let query = tabManager.tabs[0].content.query
        #expect(query.contains("'bob'"))
        #expect(!query.contains("(bob)"), "the switched row has not been applied")
    }

    @Test("A rebuild keeps the logic the filters ran with, not one changed in the panel since")
    func rebuildKeepsRunningLogicMode() {
        let (coordinator, tabManager) = makeTableCoordinator([
            TableFilter(columnName: "a", value: "1"),
            TableFilter(columnName: "b", value: "2"),
        ])
        coordinator.rebuildTableQuery(at: 0)
        #expect(tabManager.tabs[0].content.query.contains(" AND "))

        tabManager.mutate(at: 0) { $0.filterState.filterLogicMode = .or }
        coordinator.rebuildTableQuery(at: 0)

        #expect(tabManager.tabs[0].content.query.contains(" AND "))
        #expect(!tabManager.tabs[0].content.query.contains(" OR "))
    }

    @Test("Restored filters a rebuild cannot build stop counting as applied")
    func rebuildDropsRefusedApplication() {
        let (coordinator, tabManager) = makeTableCoordinator([
            TableFilter.rawCondition("status = 'a' -- temp"),
        ])

        coordinator.rebuildTableQuery(at: 0)

        let tab = tabManager.tabs[0]
        #expect(tab.filterState.applied == nil)
        #expect(!tab.filterState.isFiltering)
        #expect(!tab.content.query.contains("temp"))
        #expect(tab.filterState.filters.count == 1, "the row stays in the panel for the reader to fix")
    }

    @Test("A refused row applied alone runs nothing, not the other checked rows")
    func refusedAloneRowFallsBackToNoFilter() throws {
        let checked = TableFilter(columnName: "name", value: "bob")
        let refused = TableFilter.rawCondition("status = 'a' -- temp")
        let (coordinator, tabManager) = makeTableCoordinator([checked, refused])
        let alone = try #require(tabManager.tabs[0].filterState.applyingAlone(refused.id))
        tabManager.mutate(at: 0) { $0.filterState = alone }

        coordinator.rebuildTableQuery(at: 0)

        let tab = tabManager.tabs[0]
        #expect(tab.filterState.applied == nil)
        #expect(!tab.content.query.contains("temp"))
        #expect(!tab.content.query.contains("'bob'"))
        #expect(tab.filterState.filters.map(\.id) == [checked.id, refused.id])
    }

    @Test("Search All Rows keeps filtering after a page turn, and the panel shows the search")
    func searchAllRowsSurvivesAPageTurn() throws {
        let (coordinator, tabManager) = makeTableCoordinator([])
        defer {
            clearSavedFilters(coordinator)
            coordinator.teardown()
        }
        try #require(!tabManager.tabs[0].filterState.isFiltering)

        coordinator.filterCoordinator.applyCrossColumnSearch(
            term: "ada", columns: ["name", "email"], forTab: tabManager.tabs[0].id
        )
        let searched = tabManager.tabs[0].content.query
        #expect(searched.contains("%ada%"))

        tabManager.mutate(at: 0) {
            $0.pagination.totalRowCount = 10_000
            $0.pagination.goToPage(2)
        }
        try #require(tabManager.tabs[0].pagination.currentPage == 2)
        coordinator.rebuildTableQuery(at: 0)

        let tab = tabManager.tabs[0]
        let paged = tab.content.query
        #expect(paged != searched)
        #expect(paged.contains("OFFSET \(tab.pagination.currentOffset)"))
        #expect(paged.contains("%ada%"))
        #expect(paged.contains(" OR "))
        #expect(paged.contains("\"name\""))
        #expect(paged.contains("\"email\""))

        let state = tab.filterState
        #expect(state.isFiltering)
        #expect(state.applied?.logicMode == .or)
        #expect(state.applied?.filters.map(\.id) == state.filters.map(\.id))
        #expect(state.filters.map(\.columnName) == ["name", "email"])
        #expect(state.filters.map(\.value) == ["ada", "ada"])
        #expect(state.filters.map(\.isEnabled) == [true, true])
        #expect(state.filterLogicMode == .or)
        #expect(state.status == .applied)
        #expect(state.isVisible)
    }

    @Test("A column renamed in Structure is renamed in the panel and in what runs")
    func renamedColumnFollowsIntoFilters() {
        let draft = TableFilter(columnName: "name", value: "carol")
        let (coordinator, tabManager) = makeTableCoordinator([TableFilter(id: draft.id, columnName: "name", value: "bob")])
        defer {
            clearSavedFilters(coordinator)
            coordinator.teardown()
        }
        tabManager.mutate(at: 0) { $0.filterState.filters = [draft] }

        coordinator.followColumnChanges(
            [.modifyColumn(old: column("name"), new: column("full_name"))],
            table: "users", schema: nil, database: ""
        )

        let tab = tabManager.tabs[0]
        #expect(tab.filterState.filters.map(\.columnName) == ["full_name"])
        #expect(tab.filterState.filters.map(\.value) == ["carol"], "the unapplied edit stays a draft")
        #expect(tab.filterState.applied?.filters.map(\.columnName) == ["full_name"])
        #expect(tab.filterState.applied?.filters.map(\.value) == ["bob"])
        #expect(tab.filterState.filters.map(\.id) == [draft.id])
        #expect(tab.content.query.contains("\"full_name\""))
        #expect(!tab.content.query.contains("\"name\""))
    }

    @Test("A column dropped in Structure takes its rows out of the panel and out of what runs")
    func droppedColumnLeavesFilters() {
        let name = TableFilter(columnName: "name", value: "bob")
        let age = TableFilter(columnName: "age", filterOperator: .greaterThan, value: "18")
        let (coordinator, tabManager) = makeTableCoordinator([name, age])
        defer {
            clearSavedFilters(coordinator)
            coordinator.teardown()
        }

        coordinator.followColumnChanges([.deleteColumn(column("name"))], table: "users", schema: nil, database: "")

        let tab = tabManager.tabs[0]
        #expect(tab.filterState.filters.map(\.id) == [age.id])
        #expect(tab.filterState.applied?.filters.map(\.id) == [age.id])
        #expect(!tab.content.query.contains("\"name\""))
        #expect(tab.content.query.contains("\"age\""))
    }

    @Test("Dropping the only filtered column stops filtering")
    func droppingTheOnlyFilteredColumnStopsFiltering() {
        let (coordinator, tabManager) = makeTableCoordinator([TableFilter(columnName: "name", value: "bob")])
        defer {
            clearSavedFilters(coordinator)
            coordinator.teardown()
        }

        coordinator.followColumnChanges([.deleteColumn(column("name"))], table: "users", schema: nil, database: "")

        let tab = tabManager.tabs[0]
        #expect(tab.filterState.filters.isEmpty)
        #expect(tab.filterState.applied == nil)
        #expect(!tab.content.query.contains("'bob'"))
    }

    @Test("A Structure change leaves tabs on another table, another schema or a temporary table alone")
    func structureChangeLeavesOtherTablesAlone() {
        let (coordinator, tabManager) = makeTableCoordinator([])
        defer {
            clearSavedFilters(coordinator, schema: "public")
            coordinator.teardown()
        }
        let filter = { TableFilter(columnName: "name", value: "bob") }
        tabManager.tabs = [
            makeTab(table: "users", schema: "public", filters: [filter()]),
            makeTab(table: "orders", schema: "public", filters: [filter()]),
            makeTab(table: "users", schema: "archive", filters: [filter()]),
            makeTab(table: "users", schema: "public", filters: [filter()]),
        ]
        tabManager.tabs[3].tableContext.isTemporary = true
        tabManager.selectedTabId = tabManager.tabs[0].id
        let before = tabManager.tabs

        coordinator.followColumnChanges(
            [.modifyColumn(old: column("name"), new: column("full_name")), .deleteColumn(column("age"))],
            table: "users", schema: "public", database: ""
        )

        #expect(tabManager.tabs[0].filterState.filters.map(\.columnName) == ["full_name"])
        #expect(tabManager.tabs[0].filterState.applied?.filters.map(\.columnName) == ["full_name"])
        #expect(tabManager.tabs[1].filterState == before[1].filterState)
        #expect(tabManager.tabs[1].content.query == before[1].content.query)
        #expect(tabManager.tabs[2].filterState == before[2].filterState)
        #expect(tabManager.tabs[2].content.query == before[2].content.query)
        #expect(tabManager.tabs[3].filterState == before[3].filterState)
        #expect(tabManager.tabs[3].content.query == before[3].content.query)
    }
}
