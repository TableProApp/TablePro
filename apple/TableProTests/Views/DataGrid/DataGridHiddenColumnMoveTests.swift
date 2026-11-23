//
//  DataGridHiddenColumnMoveTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// A header drag reports the shown columns only; a query tab's store reads back an order only when it names them all.
@MainActor
struct DataGridHiddenColumnMoveTests {
    private let fixture = CoordinatorFixture()

    private func queryTabModel() -> (tabId: UUID, model: DataGridModel) {
        let columns = ["id", "name", "email", "created_at"]
        let tab = fixture.addTab(
            QueryTab(title: "Query 1", query: "SELECT id, name, email, created_at FROM users", tabType: .query),
            rows: TableRows.from(
                queryRows: [columns.map { PluginCellValue.text("\($0) value") }],
                columns: columns,
                columnTypes: Array(repeating: .text(rawType: "TEXT"), count: columns.count)
            )
        )
        return (tab.id, fixture.coordinator.gridModel(forTab: tab.id))
    }

    @Test("A column moved past a hidden one keeps its place through the next resize")
    func movedColumnSurvivesAResize() {
        let (tabId, model) = queryTabModel()
        defer { fixture.coordinator.releaseGridModel(forTab: tabId, persistingLayout: false) }
        fixture.coordinator.hideColumn("email")
        #expect(model.columns.orderedNames == ["id", "name", "created_at"])

        model.columnGeometryDidChange(widths: [:], order: ["id", "created_at", "name"])
        model.columnGeometryDidChange(widths: ["name": 200], order: nil)

        #expect(model.columns.orderedNames == ["id", "created_at", "name"])
        #expect(model.store.columnLayout.columnOrder == ["id", "created_at", "email", "name"])
    }

    @Test("A column moved past a hidden one keeps its place through a re-run of the same columns")
    func movedColumnSurvivesARerun() {
        let (tabId, model) = queryTabModel()
        defer { fixture.coordinator.releaseGridModel(forTab: tabId, persistingLayout: false) }
        fixture.coordinator.hideColumn("email")

        model.columnGeometryDidChange(widths: [:], order: ["id", "created_at", "name"])
        model.reloadRows()

        #expect(model.columns.orderedNames == ["id", "created_at", "name"])
    }

    @Test("A hidden column shown again comes back in the slot it held")
    func shownColumnReturnsToItsSlot() {
        let (tabId, model) = queryTabModel()
        defer { fixture.coordinator.releaseGridModel(forTab: tabId, persistingLayout: false) }
        fixture.coordinator.hideColumn("email")
        model.columnGeometryDidChange(widths: [:], order: ["id", "created_at", "name"])

        fixture.coordinator.showAllColumns()

        #expect(model.columns.orderedNames == ["id", "created_at", "email", "name"])
    }
}
