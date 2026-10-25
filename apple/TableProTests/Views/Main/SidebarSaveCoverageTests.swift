//
//  SidebarSaveCoverageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct SidebarSaveCoverageTests {
    private let fixtures = CoordinatorFixtures()

    private func makeCoordinator(driver: any PluginDatabaseDriver) -> MainContentCoordinator {
        let fixture = fixtures.make()
        let tabManager = fixture.tabManager
        let coordinator = fixture.coordinator
        var tab = QueryTab(title: "items", query: "db.items.find({})", tabType: .table, tableName: "items")
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("a")], [.text("2"), .text("b")]],
                columns: ["_id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                hasAuthoritativeSchema: true
            ),
            for: tab.id
        )
        coordinator.changeManager.configureForTable(
            tableName: "items",
            columns: ["_id", "name"],
            primaryKeyColumns: ["_id"],
            databaseType: DatabaseType(rawValue: "MongoDB"),
            generatedColumns: []
        )
        coordinator.changeManager.pluginDriver = driver
        return coordinator
    }

    private func selectBothRows(in coordinator: MainContentCoordinator) throws {
        let tabId = try #require(coordinator.tabManager.selectedTabId)
        coordinator.gridModel(forTab: tabId).selectRows([.existing(0), .existing(1)])
    }

    @Test("An inspector save across rows the driver cannot all write throws instead of writing some")
    func inspectorSaveRefusesAPartialWrite() throws {
        let firstRowOnly = RowWriteStubDriver { changes, _, _, _ in
            changes.prefix(1).map { PluginRowWrite(statement: "updateOne(\($0.rowIndex))", rowIndices: [$0.rowIndex]) }
        }
        let coordinator = makeCoordinator(driver: firstRowOnly)
        try selectBothRows(in: coordinator)

        #expect(throws: DataWriteError.changesNotWritable(table: "items", unwritten: UnwrittenRowCounts(updates: 1))) {
            _ = try coordinator.sidebarEditStatements(
                editedFields: [InspectorFieldEdit(columnIndex: 1, columnName: "name", newValue: "z")]
            )
        }
    }

    @Test("An inspector save the driver writes in full goes through unchanged")
    func inspectorSaveWrittenInFull() throws {
        let everyRow = RowWriteStubDriver { changes, _, _, _ in
            changes.map { PluginRowWrite(statement: "updateOne(\($0.rowIndex))", rowIndices: [$0.rowIndex]) }
        }
        let coordinator = makeCoordinator(driver: everyRow)
        try selectBothRows(in: coordinator)

        let statements = try coordinator.sidebarEditStatements(
            editedFields: [InspectorFieldEdit(columnIndex: 1, columnName: "name", newValue: "z")]
        )

        #expect(statements.map(\.sql) == ["updateOne(0)", "updateOne(1)"])
    }
}
