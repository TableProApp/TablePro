//
//  ValueFilterEditedRowTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class EditedRowLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("Value filter after an edit takes a row out of its match")
@MainActor
struct ValueFilterEditedRowTests {
    private struct Fixture {
        let coordinator: MainContentCoordinator
        let tabId: UUID
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
        coordinator.setValueFilter(nameFilter(["Bob", "Carol"]), forTab: tab.id)
        return Fixture(coordinator: coordinator, tabId: tab.id)
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

    private func mountGrid(on fixture: Fixture) -> TableViewCoordinator {
        let coordinator = fixture.coordinator
        let tabId = fixture.tabId
        let delegate = DataTabGridDelegate()
        let grid = TableViewCoordinator(
            changeManager: AnyChangeManager(coordinator.changeManager),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: delegate,
            layoutPersister: EditedRowLayoutPersister()
        )
        delegate.dataGridAttach(tableViewCoordinator: grid)
        coordinator.dataTabDelegate = delegate
        grid.tableRowsProvider = { [weak coordinator] in
            coordinator?.tabSessionRegistry.existingTableRows(for: tabId) ?? TableRows()
        }
        grid.tableRowsMutator = { [weak coordinator] mutate in
            coordinator?.mutateActiveTableRows(for: tabId) { rows in mutate(&rows) } ?? .none
        }
        grid.valueFilterBinding = Binding(
            get: { coordinator.tabManager.tabs.first { $0.id == tabId }?.valueFilter ?? GridValueFilterState() },
            set: { coordinator.setValueFilter($0, forTab: tabId) }
        )
        grid.displayOrderProvider = { [weak coordinator] in
            coordinator?.displayIDs(forTab: tabId)
        }
        grid.adoptValueFilter(coordinator.tabManager.tabs.first { $0.id == tabId }?.valueFilter ?? GridValueFilterState())
        grid.recomputeValueFilteredIDs()
        grid.updateCache()
        return grid
    }

    private func renameBobInStorage(_ fixture: Fixture, to name: String) {
        fixture.coordinator.mutateActiveTableRows(for: fixture.tabId) { rows in
            rows.edit(row: 1, column: 1, value: .text(name))
        }
    }

    private func stringParameters(_ statement: ParameterizedStatement) -> [String] {
        statement.parameters.compactMap { $0 as? String }
    }

    @Test("an edit that takes a row out of the filter leaves it at its display position")
    func editKeepsTheRowInTheDisplayOrder() {
        let fixture = makeFixture()
        #expect(fixture.coordinator.activeGridDisplayIDs == [.existing(1), .existing(2)])

        renameBobInStorage(fixture, to: "Zed")

        #expect(fixture.coordinator.activeGridDisplayIDs == [.existing(1), .existing(2)])
    }

    @Test("the order is resolved when the filter is set, not when a reader first asks for it")
    func orderDoesNotDependOnWhenItIsFirstRead() {
        let fixture = makeFixture()
        renameBobInStorage(fixture, to: "Zed")

        #expect(fixture.coordinator.activeGridDisplayIDs == [.existing(1), .existing(2)])
    }

    @Test("the mounted grid and the owner agree on the display order after an inline edit")
    func gridAndOwnerAgreeAfterAnInlineEdit() {
        let fixture = makeFixture()
        let grid = mountGrid(on: fixture)

        grid.recordCellEdit(row: 0, columnIndex: 1, newValue: .text("Zed"))
        grid.recomputeValueFilteredIDs()

        #expect(grid.displayIDs == [.existing(1), .existing(2)])
        #expect(grid.displayIDs == fixture.coordinator.activeGridDisplayIDs)
        #expect(grid.displayRow(at: 0)?.values[1] == .text("Zed"))
    }

    @Test("a grid with an owner shows the owner's order rather than resolving its own")
    func gridTakesTheOwnersOrder() {
        let fixture = makeFixture()
        let grid = mountGrid(on: fixture)
        grid.displayOrderProvider = { [.existing(2)] }

        grid.recomputeValueFilteredIDs()

        #expect(grid.displayIDs == [.existing(2)])
    }

    @Test("deleting the row the grid shows after an edit deletes that row and no other")
    func deleteAfterAnEditTargetsTheShownRow() throws {
        let fixture = makeFixture()
        let grid = mountGrid(on: fixture)
        grid.recordCellEdit(row: 0, columnIndex: 1, newValue: .text("Zed"))

        fixture.coordinator.deleteSelectedRows(indices: [0])

        let deletes = try fixture.coordinator.changeManager.generateSQL()
            .filter { $0.sql.hasPrefix("DELETE") }
        #expect(deletes.count == 1)
        let parameters = deletes.first.map(stringParameters) ?? []
        #expect(parameters.contains("2"))
        #expect(!parameters.contains("3"))
    }

    @Test("a row inspector save after an edit updates the row the grid shows")
    func sidebarSaveAfterAnEditTargetsTheShownRow() throws {
        let fixture = makeFixture()
        renameBobInStorage(fixture, to: "Zed")
        fixture.coordinator.selectionState.indices = [0]

        let statements = try fixture.coordinator.sidebarEditStatements(
            editedFields: [(columnIndex: 1, columnName: "name", newValue: "Yan")]
        )

        #expect(statements.count == 1)
        let parameters = statements.first.map(stringParameters) ?? []
        #expect(parameters.contains("Yan"))
        #expect(parameters.contains("2"))
        #expect(!parameters.contains("3"))
    }

    @Test("adding a row re-resolves the order, so the edited row leaves with the next row-set change")
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
        #expect(fixture.coordinator.activeGridDisplayIDs == [RowID.existing(2), insertedID])
    }

    @Test("changing the filter re-resolves the order over the edited values")
    func changingTheFilterReResolvesTheOrder() {
        let fixture = makeFixture()
        renameBobInStorage(fixture, to: "Zed")

        fixture.coordinator.setValueFilter(nameFilter(["Zed"]), forTab: fixture.tabId)

        #expect(fixture.coordinator.activeGridDisplayIDs == [.existing(1)])
    }
}
