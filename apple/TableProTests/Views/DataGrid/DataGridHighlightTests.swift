//
//  DataGridHighlightTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class HighlightGrid {
    let owner: GridTestOwner
    let model: DataGridModel
    let presenter: DataGridCellPresenter

    init(statuses: [String]) {
        let rows = TableRows.from(
            queryRows: statuses.enumerated().map { index, status in [PluginCellValue.text("\(index)"), .text(status)] },
            columns: ["id", "status"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR")]
        )
        owner = GridTestOwner(rows)
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        model = DataGridModel(configuration: configuration)
        model.dataSource = owner
        model.actions = owner
        owner.model = model
        owner.appliesCommits = true
        model.reloadRows()
        presenter = DataGridCellPresenter(model: model)
    }

    // The presenter reads the owner's rules at draw time; this is the step a row draw takes first.
    func apply(_ rules: [HighlightRule]) {
        owner.highlightRules = rules
        presenter.prepareRowState(rows: model.rows)
    }

    func rowColor(_ displayRow: Int) -> HighlightColor? {
        guard let row = model.row(at: displayRow) else { return nil }
        presenter.prepareRowState(rows: model.rows)
        return presenter.visualState(of: row).highlight.rowColor
    }
}

@MainActor
struct DataGridHighlightTests {
    private let paid = HighlightRule(columnName: "status", value: "paid", color: .green)

    @Test("Only the rows a rule matches carry its highlight")
    func matchingRowsCarryTheHighlight() {
        let grid = HighlightGrid(statuses: ["paid", "pending", "paid"])
        grid.apply([paid])

        #expect(grid.rowColor(0) == .green)
        #expect(grid.rowColor(1) == nil)
        #expect(grid.rowColor(2) == .green)
    }

    @Test("Changing the rules recolours rows already evaluated, and the same rules keep their key")
    func changingRulesRecolours() {
        let grid = HighlightGrid(statuses: ["paid"])
        grid.apply([paid])
        #expect(grid.rowColor(0) == .green)
        let firstKey = grid.model.display.highlightRuleSetKey

        var recolored = paid
        recolored.color = .red
        grid.apply([recolored])
        #expect(grid.rowColor(0) == .red)
        let secondKey = grid.model.display.highlightRuleSetKey
        #expect(secondKey != firstKey)

        grid.apply([recolored])
        #expect(grid.model.display.highlightRuleSetKey == secondKey)
    }

    @Test("An edit that flips a rule is reflected once the edit commits")
    func editFlipsTheHighlight() {
        let grid = HighlightGrid(statuses: ["pending"])
        grid.apply([paid])
        #expect(grid.rowColor(0) == nil)

        let committed = grid.model.commit(
            [DataGridCellEdit(rowID: .existing(0), columnID: DataGridColumnID(name: "status", occurrence: 0), value: .enteredText("paid"))],
            actionName: "Edit Cell"
        )

        #expect(committed)
        #expect(grid.owner.tableRows.rows[0].values[1] == .text("paid"))
        #expect(grid.rowColor(0) == .green)
    }

    @Test("Rows replaced under the same positional ids are evaluated afresh on reload")
    func positionalIdsAreNotServedStaleHighlights() {
        let grid = HighlightGrid(statuses: ["paid"])
        grid.apply([paid])
        #expect(grid.rowColor(0) == .green)

        grid.owner.tableRows.rows[0].values[1] = .text("pending")
        grid.model.reloadRows()

        #expect(grid.rowColor(0) == nil)
    }

    @Test("A grid whose owner supplies its own row state is never highlighted")
    func ownerStateSuppressesHighlights() {
        let grid = HighlightGrid(statuses: ["paid"])
        grid.owner.visualStates[.existing(0)] = .empty
        grid.apply([paid])

        #expect(grid.rowColor(0) == nil)
    }

    @Test("The accessibility description names the rule that coloured the cell")
    func accessibilityDescription() throws {
        let grid = HighlightGrid(statuses: ["paid"])
        grid.apply([paid])
        let row = try #require(grid.model.row(at: 0))

        #expect(grid.presenter.highlightDescription(of: row, dataIndex: 0) == "status = \u{201C}paid\u{201D}")
    }

    @Test("A highlighted row tints its whole row in the rule's color")
    func highlightedRowTint() throws {
        let grid = HighlightGrid(statuses: ["paid", "pending"])
        grid.apply([paid])
        let highlighted = try #require(grid.model.row(at: 0))
        let plain = try #require(grid.model.row(at: 1))

        #expect(grid.presenter.visualState(of: highlighted).tint(in: .live) == HighlightColor.green.washColor)
        #expect(grid.presenter.visualState(of: plain).tint(in: .live) == nil)
    }

    // MARK: - Repaint

    @Test("A value change repaints its whole row where a row rule can wash it, else only the changed column")
    func rowRuleRepaintsWholeRow() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people) { owner, _ in
            owner.highlightRules = [HighlightRule(columnName: "name", value: "bob", color: .green)]
        }
        defer { grid.close() }
        _ = try #require(grid.main.rowView(atRow: 1, makeIfNecessary: true))
        _ = try #require(grid.frozen.rowView(atRow: 1, makeIfNecessary: true))

        #expect(grid.controller.refreshRowState(IndexSet(integer: 1), columns: IndexSet(integer: 1)) == IndexSet(integer: 1))

        grid.owner.highlightRules = [HighlightRule(columnName: "name", value: "bob", color: .green, target: .cell)]

        #expect(grid.controller.refreshRowState(IndexSet(integer: 1), columns: IndexSet(integer: 1)).isEmpty)
    }

    @Test("A value change on a row whose pending mark moved repaints the whole row")
    func movedMarkRepaintsWholeRow() throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "people",
            columns: ["id", "name", "age"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        let grid = HostedDataGrid(rows: GridFixtureRows.people, changeManager: manager)
        defer { grid.close() }
        _ = try #require(grid.main.rowView(atRow: 2, makeIfNecessary: true))
        manager.recordRowDeletion(rowID: .existing(2), originalRow: [.text("2"), .text("cid"), .text("25")])
        grid.model.repaintRows([RowID.existing(2)])
        try #require(grid.controller.rowTint(forRow: 2) != nil)

        manager.undoRowDeletion(rowID: .existing(2))

        #expect(grid.controller.refreshRowState(IndexSet(integer: 2), columns: IndexSet(integer: 1)) == IndexSet(integer: 2))
        #expect(grid.controller.rowTint(forRow: 2) == nil)
    }
}
