//
//  QueryContainerChangeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct QueryContainerChangeTests {
    private func queryTab(database: String, schema: String? = nil) -> QueryTab {
        var tab = QueryTab(title: "Query 1", query: "SELECT * FROM users", tabType: .query)
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    // Rows read from `users`, the way a finished run leaves them: editable, keyed, with more to load.
    private func showRows(on tab: inout QueryTab, database: String, schema: String?) {
        let rows = ResultSet(
            label: "users",
            tableRows: TableRows.from(queryRows: [[.text("42")]], columns: ["id"], columnTypes: [.text(rawType: "INTEGER")])
        )
        rows.origin = ResultOrigin(
            tableName: "users",
            schemaName: schema,
            databaseName: database,
            primaryKeyColumns: ["id"],
            isEditable: true,
            keysResolved: true
        )
        tab.display.resultSets = [rows]
        tab.tableContext.tableName = "users"
        tab.tableContext.isEditable = true
        tab.pagination.hasMoreRows = true
        tab.pagination.baseQueryForMore = "SELECT * FROM users"
    }

    @Test("The picker does not move a tab while its query runs")
    func runningTabKeepsItsDatabase() {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(queryTab(database: "staging"))
        let running = fixture.coordinator.tabExecution.claim(tab.id)

        fixture.coordinator.changeQueryContainer(of: tab.id, to: "production", target: .database)

        #expect(fixture.coordinator.tabExecution.isCurrent(running))
        #expect(fixture.tabManager.tabs.first { $0.id == tab.id }?.tableContext.databaseName == "staging")
    }

    @Test("Rows still on screen from the old database cannot be edited or paged from the new one")
    func movedTabLeavesTheOldRowsReadOnly() {
        let fixture = CoordinatorFixture()
        fixture.coordinator.executionGate = AlwaysDenyGate.cancelling
        var tab = queryTab(database: "staging")
        showRows(on: &tab, database: "staging", schema: nil)
        fixture.addTab(tab)
        #expect(fixture.coordinator.activeResultEditRefusal == nil)

        fixture.coordinator.changeQueryContainer(of: tab.id, to: "production", target: .database)

        let moved = fixture.tabManager.tabs.first { $0.id == tab.id }
        #expect(moved?.tableContext.databaseName == "production")
        #expect(moved?.pagination.hasMoreRows == false)
        #expect(moved?.pagination.baseQueryForMore == nil)
        #expect(fixture.coordinator.activeResultEditRefusal == .databaseMoved)
    }

    @Test("Rows left from the old schema after the schema picker moved the tab cannot be edited")
    func schemaPickerLeavesTheOldRowsReadOnly() {
        let fixture = CoordinatorFixture()
        fixture.coordinator.executionGate = AlwaysDenyGate.cancelling
        var tab = queryTab(database: "app", schema: "staging")
        showRows(on: &tab, database: "app", schema: "staging")
        fixture.addTab(tab)
        #expect(fixture.coordinator.activeResultEditRefusal == nil)

        fixture.coordinator.changeQueryContainer(of: tab.id, to: "production", target: .schema)

        #expect(fixture.tabManager.tabs.first { $0.id == tab.id }?.tableContext.schemaName == "production")
        #expect(fixture.coordinator.activeResultEditRefusal == .schemaMoved)
    }

    @Test("Showing a pinned result read in another schema leaves the tab where the picker put it, and offers no Fetch All")
    func resultSwitchKeepsTheSchemaBinding() throws {
        let fixture = CoordinatorFixture()
        var tab = queryTab(database: "app", schema: "staging")
        showRows(on: &tab, database: "app", schema: "staging")
        let stagingResult = try #require(tab.display.resultSets.first)
        stagingResult.isTruncated = true
        stagingResult.baseQuery = "SELECT * FROM users"
        let productionResult = ResultSet(label: "Result 2")
        productionResult.origin = ResultOrigin(tableName: nil, schemaName: "production", databaseName: "app")
        tab.display.resultSets.append(productionResult)
        tab.display.activeResultSetId = productionResult.id
        tab.tableContext.schemaName = "production"
        fixture.addTab(tab)

        fixture.coordinator.applyResultSetSwitch(to: stagingResult.id, in: tab.id)

        let switched = fixture.tabManager.tabs.first { $0.id == tab.id }
        #expect(switched?.tableContext.schemaName == "production")
        #expect(switched?.pagination.hasMoreRows == false)
        #expect(switched?.pagination.baseQueryForMore == nil)
        #expect(fixture.coordinator.activeResultEditRefusal == .schemaMoved)
    }
}
