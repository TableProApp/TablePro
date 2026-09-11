//
//  TableViewCoordinatorHighlightTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class HighlightTestPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class StructureStateDelegate: DataGridViewDelegate {
    func dataGridVisualState(forRow row: Int) -> RowVisualState? { .empty }
}

@MainActor
private final class HighlightGrid {
    var tableRows: TableRows
    let coordinator: TableViewCoordinator

    init(statuses: [String], delegate: (any DataGridViewDelegate)? = nil) {
        let rows = ContiguousArray(statuses.enumerated().map { index, status in
            Row(id: .existing(index), values: [.text("\(index)"), .text(status)])
        })
        tableRows = TableRows(
            rows: rows,
            columns: ["id", "status"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR")]
        )
        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: delegate,
            layoutPersister: HighlightTestPersister()
        )
        coordinator.tableRowsProvider = { [weak self] in self?.tableRows ?? TableRows() }
        coordinator.tableRowsMutator = { [weak self] mutation in
            guard let self else { return }
            mutation(&self.tableRows)
        }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()
    }

    @discardableResult
    func apply(_ rules: [HighlightRule]) -> Bool {
        coordinator.syncHighlightRules(rules, tableRows: tableRows)
    }

    func rowColor(_ row: Int) -> HighlightColor? {
        coordinator.visualState(for: row).highlight.rowColor
    }
}

@Suite("Grid coordinator highlight rules")
@MainActor
struct TableViewCoordinatorHighlightTests {
    private let paid = HighlightRule(columnName: "status", value: "paid", color: .green)

    @Test("Only the rows a rule matches carry its highlight")
    func matchingRowsCarryTheHighlight() {
        let grid = HighlightGrid(statuses: ["paid", "pending", "paid"])
        grid.apply([paid])

        #expect(grid.rowColor(0) == .green)
        #expect(grid.rowColor(1) == nil)
        #expect(grid.rowColor(2) == .green)
    }

    @Test("Changing the rules reports a change and recolours rows already evaluated")
    func changingRulesRecolours() {
        let grid = HighlightGrid(statuses: ["paid"])
        #expect(grid.apply([paid]))
        #expect(grid.rowColor(0) == .green)

        var recolored = paid
        recolored.color = .red
        #expect(grid.apply([recolored]))
        #expect(grid.rowColor(0) == .red)
        #expect(!grid.apply([recolored]))
    }

    @Test("An edit that flips a rule is reflected once the edit commits")
    func editFlipsTheHighlight() {
        let grid = HighlightGrid(statuses: ["pending"])
        grid.apply([paid])
        #expect(grid.rowColor(0) == nil)

        grid.coordinator.commitTypedCellEdit(row: 0, columnIndex: 1, newValue: .text("paid"))

        #expect(grid.tableRows.rows[0].values[1] == .text("paid"))
        #expect(grid.rowColor(0) == .green)
    }

    @Test("New rows under the same positional ids are evaluated afresh once the cache is dropped")
    func positionalIdsAreNotServedStaleHighlights() {
        let grid = HighlightGrid(statuses: ["paid"])
        grid.apply([paid])
        #expect(grid.rowColor(0) == .green)

        grid.tableRows.rows[0].values[1] = .text("pending")
        grid.coordinator.invalidateDisplayCache()

        #expect(grid.rowColor(0) == nil)
    }

    @Test("A fresh display state for a new page carries no highlights from the old one")
    func freshDisplayStateStartsClean() {
        let grid = HighlightGrid(statuses: ["paid"])
        grid.apply([paid])
        #expect(grid.rowColor(0) == .green)

        grid.tableRows.rows[0].values[1] = .text("pending")
        grid.coordinator.adoptDisplayState(DataGridDisplayState())
        grid.apply([paid])

        #expect(grid.rowColor(0) == nil)
    }

    @Test("A grid whose owner supplies its own row state is never highlighted")
    func delegateStateSuppressesHighlights() {
        let delegate = StructureStateDelegate()
        let grid = HighlightGrid(statuses: ["paid"], delegate: delegate)
        grid.apply([paid])

        #expect(grid.rowColor(0) == nil)
    }

    @Test("The accessibility description names the rule that coloured the cell")
    func accessibilityDescription() {
        let grid = HighlightGrid(statuses: ["paid"])
        grid.apply([paid])

        #expect(grid.coordinator.highlightDescription(row: 0, columnIndex: 0) == "status = “paid”")
    }
}
