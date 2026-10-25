//
//  ValueFilterEditedRowTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ValueFilterEditedRowTests {
    @MainActor
    private struct Fixture {
        let coordinator: MainContentCoordinator
        let tabId: UUID

        var model: DataGridModel {
            coordinator.gridModel(forTab: tabId)
        }

        // The primary key of the row the grid shows at a position, which is what a write names.
        func shownKey(at displayRow: Int) -> String? {
            model.row(at: displayRow)?.values[0].asText
        }
    }

    private func makeFixture() -> Fixture {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [
                    [.text("1"), .text("Alice")],
                    [.text("2"), .text("Bob")],
                    [.text("3"), .text("Carol")]
                ],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                hasAuthoritativeSchema: true
            ),
            for: tab.id
        )
        coordinator.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        let fixture = Fixture(coordinator: coordinator, tabId: tab.id)
        fixture.model.setValueFilter(nameFilter(["Bob", "Carol"]))
        return fixture
    }

    private func nameFilter(_ names: Set<String>) -> GridValueFilterState {
        var state = GridValueFilterState()
        state.set(
            ColumnValueFilter(selectedValues: names, includesNull: false),
            columnName: "name",
            forColumn: 1
        )
        return state
    }

    private func renameBobInStorage(_ fixture: Fixture, to name: String) {
        fixture.coordinator.mutateActiveTableRows(for: fixture.tabId) { rows in
            rows.edit(row: 1, column: 1, value: .text(name))
        }
    }

    // An inline edit the way the grid commits one: through the model, by row and column identity.
    private func editBobInTheGrid(_ fixture: Fixture, to name: String) throws {
        let model = fixture.model
        model.configuration.isEditable = true
        let position = try #require(model.columns.displayPosition(ofDataIndex: 1))
        let column = try #require(model.columns.column(at: position))
        let committed = model.commit(
            [DataGridCellEdit(rowID: .existing(1), columnID: column.id, value: .value(.text(name), isExpression: false))],
            actionName: "Edit"
        )
        try #require(committed)
    }

    private func stringParameters(_ statement: ParameterizedStatement) -> [String] {
        statement.parameters.compactMap { $0 as? String }
    }

    @Test("an edit that takes a row out of the filter keeps it in the display order")
    func editKeepsTheRowInTheDisplayOrder() {
        let fixture = makeFixture()
        #expect(fixture.model.displayedRowIDs == [.existing(1), .existing(2)])

        renameBobInStorage(fixture, to: "Zed")

        #expect(fixture.model.displayedRowIDs == [.existing(1), .existing(2)])
    }

    @Test("the order is resolved when the filter is set, not when a reader first asks for it")
    func orderDoesNotDependOnWhenItIsFirstRead() {
        let fixture = makeFixture()
        renameBobInStorage(fixture, to: "Zed")

        #expect(fixture.model.displayedRowIDs == [.existing(1), .existing(2)])
    }

    @Test("the grid and the window read one display order after an inline edit")
    func gridAndOwnerAgreeAfterAnInlineEdit() throws {
        let fixture = makeFixture()

        try editBobInTheGrid(fixture, to: "Zed")

        #expect(fixture.coordinator.changeManager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(fixture.coordinator.tabSessionRegistry.tableRows(for: fixture.tabId).rows[1].values[1] == .text("Zed"))
        #expect(fixture.coordinator.displayIDs(forTab: fixture.tabId) == fixture.model.displayedRowIDs)
    }

    @Test("deleting the row the grid shows after an edit deletes that row and no other")
    func deleteAfterAnEditTargetsTheShownRow() throws {
        let fixture = makeFixture()
        try editBobInTheGrid(fixture, to: "Zed")
        let shown = try #require(fixture.model.rowID(at: 0))
        let shownKey = try #require(fixture.shownKey(at: 0))

        fixture.coordinator.deleteRows([shown])

        let deletes = try fixture.coordinator.changeManager.generateSQL()
            .filter { $0.sql.hasPrefix("DELETE") }
        #expect(deletes.count == 1)
        let parameters = deletes.first.map(stringParameters) ?? []
        let otherKeys = Set(["1", "2", "3"]).subtracting([shownKey])
        #expect(parameters.contains(shownKey))
        #expect(otherKeys.isDisjoint(with: parameters))
    }

    @Test("a row inspector save after an edit updates the row the grid shows")
    func sidebarSaveAfterAnEditTargetsTheShownRow() throws {
        let fixture = makeFixture()
        renameBobInStorage(fixture, to: "Zed")
        fixture.model.setSelection(GridSelectionReducer.single(GridCoord(row: 0, displayColumn: 0)))
        let shownKey = try #require(fixture.shownKey(at: 0))

        let statements = try fixture.coordinator.sidebarEditStatements(
            editedFields: [InspectorFieldEdit(columnIndex: 1, columnName: "name", newValue: "Yan")]
        )

        #expect(statements.count == 1)
        let parameters = statements.first.map(stringParameters) ?? []
        #expect(parameters.contains("Yan"))
        let otherKeys = Set(["1", "2", "3"]).subtracting([shownKey])
        #expect(parameters.contains(shownKey))
        #expect(otherKeys.isDisjoint(with: parameters))
    }

    @Test("adding a row re-resolves the order over the edited values")
    func addingARowReResolvesTheOrder() {
        let fixture = makeFixture()
        renameBobInStorage(fixture, to: "Zed")

        fixture.coordinator.mutateActiveTableRows(for: fixture.tabId) { rows in
            rows.appendInsertedRow(values: [.text("4"), .text("Dan")])
        }

        guard let insertedID = fixture.coordinator.tabSessionRegistry.tableRows(for: fixture.tabId).rows.last?.id else {
            Issue.record("no inserted row")
            return
        }
        #expect(insertedID.isInserted)
        #expect(fixture.model.displayedRowIDs == [RowID.existing(2), insertedID])
    }

    @Test("changing the filter re-resolves the order over the edited values")
    func changingTheFilterReResolvesTheOrder() {
        let fixture = makeFixture()
        renameBobInStorage(fixture, to: "Zed")

        fixture.model.setValueFilter(nameFilter(["Zed"]))

        #expect(fixture.model.displayedRowIDs == [.existing(1)])
    }
}
