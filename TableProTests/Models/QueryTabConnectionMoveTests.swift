//
//  QueryTabConnectionMoveTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct QueryTabConnectionMoveTests {
    private func move(
        _ tab: QueryTab,
        databaseName: String = "prod",
        schemaName: String? = nil,
        existingTabs: [QueryTab] = []
    ) -> QueryTab {
        tab.movedToConnection(
            databaseName: databaseName,
            schemaName: schemaName,
            existingTabs: existingTabs,
            defaultPageSize: 100
        )
    }

    @Test("The text, file buffer, parameters, caret and folds move with the tab")
    func contentMovesWhole() {
        var tab = QueryTab(title: "Query 3", query: "SELECT 1 FROM t", tabType: .query)
        tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/move-tab-test.sql")
        tab.content.savedFileContent = "SELECT 1"
        tab.content.queryParameters = [QueryParameter(name: "id", value: "7")]
        tab.content.isParameterPanelVisible = true
        tab.restoredCursorOffset = 4
        tab.restoredCursorLength = 2
        tab.collapsedFoldRanges = [0..<6]
        tab.hasUserInteraction = true

        let moved = move(tab)

        #expect(moved.id == tab.id)
        #expect(moved.title == "Query 3")
        #expect(moved.tabType == .query)
        #expect(moved.content == tab.content)
        #expect(moved.content.isFileDirty)
        #expect(moved.restoredCursorOffset == 4)
        #expect(moved.restoredCursorLength == 2)
        #expect(moved.collapsedFoldRanges == [0..<6])
        #expect(moved.hasUserInteraction)
    }

    @Test("The binding takes the target's browse scope and nothing else from the old context")
    func tableContextIsRebound() {
        var tab = QueryTab(title: "Query 1", query: "SELECT * FROM users", tabType: .query)
        tab.tableContext = TabTableContext(
            tableName: "users",
            databaseName: "dev",
            schemaName: "app",
            primaryKeyColumns: ["id"],
            isEditable: true,
            isView: true,
            objectType: .view
        )

        let moved = move(tab, databaseName: "prod", schemaName: "public")

        #expect(moved.tableContext == TabTableContext(databaseName: "prod", schemaName: "public"))
    }

    @Test("Results, execution and grid state stay behind")
    func resultStateIsReset() {
        var tab = QueryTab(title: "Query 1", query: "SELECT a FROM t", tabType: .query)
        tab.execution.lastExecutedAt = Date()
        tab.execution.errorMessage = "boom"
        tab.execution.rowsAffected = 4
        tab.columnLayout.columnWidths = ["a": 120]
        tab.columnLayout.hiddenColumns = ["b"]
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .descending, columnName: "a")],
            source: .user
        )
        tab.selectedRowIndices = [2]
        tab.pendingChanges.deletedRowIDs = [.existing(0)]

        let moved = move(tab)

        #expect(moved.execution == TabExecutionState())
        #expect(moved.execution.lastExecutedAt == nil)
        #expect(moved.columnLayout == ColumnLayoutState())
        #expect(!moved.sortState.isSorting)
        #expect(moved.pendingRestoredSort == nil)
        #expect(moved.restoredSortSource == .unset)
        #expect(moved.selectedRowIndices.isEmpty)
        #expect(!moved.pendingChanges.hasChanges)
        #expect(moved.display.resultSets.isEmpty)
    }

    @Test("A default title the target already uses is renumbered")
    func collidingDefaultTitleIsRenumbered() {
        let tab = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let existing = [
            QueryTab(title: "Query 1", tabType: .query),
            QueryTab(title: "Query 2", tabType: .query),
        ]

        #expect(move(tab, existingTabs: existing).title == "Query 3")
    }

    @Test("A default title the target does not use is kept")
    func freeDefaultTitleIsKept() {
        let tab = QueryTab(title: "Query 4", query: "SELECT 1", tabType: .query)

        #expect(move(tab, existingTabs: [QueryTab(title: "Query 1", tabType: .query)]).title == "Query 4")
    }

    @Test("A title the user gave the tab is never renumbered")
    func customTitleIsKept() {
        let tab = QueryTab(title: "Monthly report", query: "SELECT 1", tabType: .query)
        let existing = [QueryTab(title: "Monthly report", tabType: .query)]

        #expect(move(tab, existingTabs: existing).title == "Monthly report")
    }

    @Test("Only numbered Query titles count as defaults")
    func defaultTitleDetection() {
        #expect(QueryTab.isDefaultQueryTitle("Query 1"))
        #expect(QueryTab.isDefaultQueryTitle("Query 12"))
        #expect(!QueryTab.isDefaultQueryTitle("Query"))
        #expect(!QueryTab.isDefaultQueryTitle("Query one"))
        #expect(!QueryTab.isDefaultQueryTitle("cleanup.sql"))
    }
}
