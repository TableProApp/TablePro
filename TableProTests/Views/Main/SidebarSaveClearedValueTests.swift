//
//  SidebarSaveClearedValueTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct SidebarSaveClearedValueTests {
    private let fixture = CoordinatorFixture()

    private func makeCoordinator() -> MainContentCoordinator {
        let tabManager = fixture.tabManager
        let coordinator = fixture.coordinator
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.execution.lastExecutedAt = Date()
        tab.display.resultsViewMode = .data
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("2024-01-01 10:00:00"), .text("Alice")]],
                columns: ["id", "deleted_at", "name"],
                columnTypes: [.integer(rawType: "INT"), .datetime(rawType: "DATETIME"), .text(rawType: "VARCHAR(255)")],
                hasAuthoritativeSchema: true
            ),
            for: tab.id
        )
        coordinator.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "deleted_at", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        coordinator.selectionState.indices = [0]
        return coordinator
    }

    @Test("An inspector save of a cleared date binds NULL")
    func clearedDateBindsNull() throws {
        let coordinator = makeCoordinator()

        let statements = try coordinator.sidebarEditStatements(
            editedFields: [InspectorFieldEdit(columnIndex: 1, columnName: "deleted_at", newValue: "")]
        )

        let statement = try #require(statements.first)
        #expect(statement.sql.contains("`deleted_at` = ?"))
        let boundValue = try #require(statement.parameters.first)
        #expect(boundValue == nil)
    }

    @Test("An inspector save of a cleared text field binds the empty string")
    func clearedTextBindsEmpty() throws {
        let coordinator = makeCoordinator()

        let statements = try coordinator.sidebarEditStatements(
            editedFields: [InspectorFieldEdit(columnIndex: 2, columnName: "name", newValue: "")]
        )

        let statement = try #require(statements.first)
        #expect(statement.parameters.first.flatMap { $0 as? String } == "")
    }
}
