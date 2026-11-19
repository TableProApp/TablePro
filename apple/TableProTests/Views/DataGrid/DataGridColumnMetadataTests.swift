//
//  DataGridColumnMetadataTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridColumnMetadataTests {
    // Both columns frozen, with one point to spare: any accessory on "name" pushes it into the main pane.
    private func gridWithNameAtTheFrozenEdge() throws -> EditingGrid {
        var layout = ColumnLayoutState()
        layout.frozenColumnCount = 2
        let longName = String(repeating: "wide value ", count: 4)
        let rows = TableRows.from(
            queryRows: [[.text("0"), .text(longName)], [.text("1"), .text(longName)]],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        let grid = EditingGrid(rows: rows, store: InMemoryDataGridStateStore(columnLayout: layout))
        let main = grid.controller.main
        let name = try #require(main.tableColumn(for: DataGridColumnID(name: "name", occurrence: 0)))
        let spacing = main.tableView.intercellSpacing.width
        let available = grid.controller.container.bounds.width * DataGridMetrics.maximumFrozenShare
        let rowNumbers = (main.rowNumberTableColumn?.width ?? 0) + spacing
        grid.model.updateColumnLayout {
            $0.columnWidths["id"] = available - rowNumbers - name.width - 2 * spacing - 1
        }
        grid.controller.view.layoutSubtreeIfNeeded()
        try #require(grid.controller.effectiveFrozenCount == 2)
        return grid
    }

    @Test("Metadata arriving while a cell is edited leaves the editor open")
    func metadataLeavesTheEditorOpen() throws {
        let grid = EditingGrid()
        defer { grid.tearDown() }
        grid.select(0, 1)
        try #require(grid.controller.beginEditingCell(row: 0, displayColumn: 1))
        grid.type("typed")

        grid.model.apply(grid.owner.tableRows.updateDisplayMetadata(columnComments: ["name": "Given name"]))

        #expect(grid.controller.isEditingCell)
        #expect(grid.fieldEditor?.string == "typed")
    }

    @Test("An editor in a column that metadata pushes out of the frozen pane keeps what was typed")
    func metadataMovingAFrozenColumnKeepsTheEdit() throws {
        let grid = try gridWithNameAtTheFrozenEdge()
        defer { grid.tearDown() }
        try #require(grid.controller.beginEditingCell(row: 0, displayColumn: 1))
        grid.type("typed")

        grid.owner.tableRows.columnEnumValues["name"] = ["ann", "bob", "cid"]
        grid.model.apply(.columnMetadataChanged)

        try #require(grid.controller.effectiveFrozenCount == 1)
        #expect(grid.controller.isEditingCell)
        #expect(grid.fieldEditor?.string == "typed")
    }

    @Test("A popover over a column that metadata pushes out of the frozen pane closes")
    func metadataMovingAFrozenColumnClosesItsPopover() throws {
        let grid = try gridWithNameAtTheFrozenEdge()
        defer { grid.tearDown() }
        let cell = try #require(grid.controller.editCell(at: GridCoord(row: 0, displayColumn: 1)))
        let state = grid.controller.editingState
        state.typedPopover = NSPopover()
        state.typedPopoverRow = grid.controller.heldRow(cell)
        state.typedPopoverPane = .frozen

        grid.owner.tableRows.columnEnumValues["name"] = ["ann", "bob", "cid"]
        grid.model.apply(.columnMetadataChanged)

        try #require(grid.controller.effectiveFrozenCount == 1)
        #expect(state.typedPopover == nil)
    }

    @Test("Enum labels arriving after the rows give the column its accessory and keep the text")
    func enumLabelsRefreshThePresentation() throws {
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration)
        defer { grid.close() }
        grid.model.display.cache.setBox(RowDisplayBox(["0", "ann", "30"]), forID: .existing(0))
        #expect(grid.controller.presenter.presentation(forDataIndex: 1).accessory == .none)

        grid.owner.tableRows.columnEnumValues["name"] = ["ann", "bob"]
        grid.model.apply(.columnMetadataChanged)

        #expect(grid.controller.presenter.presentation(forDataIndex: 1).accessory != .none)
        #expect(grid.model.display.cache.box(forID: .existing(0)) != nil)
    }

    @Test("A comment arriving after the rows reaches the column's header")
    func commentsReachTheHeader() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let column = try #require(grid.tableColumn(named: "name"))

        grid.model.apply(grid.owner.tableRows.updateDisplayMetadata(columnComments: ["name": "Given name"]))

        #expect(grid.model.columns.column(at: 1)?.comment == "Given name")
        #expect(column.headerToolTip?.contains("Given name") == AppSettingsManager.shared.general.showObjectComments)
    }

    @Test("Repainting every row reads the marks staged and cleared since the last reload")
    func repaintingEveryRowRebuildsTheMarks() throws {
        let manager = DataChangeManager()
        let grid = HostedDataGrid(rows: GridFixtureRows.people, changeManager: manager)
        defer { grid.close() }
        let row = try #require(grid.model.row(at: 1))

        manager.recordRowDeletion(rowID: row.id, originalRow: Array(row.values))
        grid.model.repaintAllRows()
        #expect(grid.controller.presenter.visualState(of: row).isDeleted)

        manager.clearChanges()
        grid.model.repaintAllRows()
        #expect(!grid.controller.presenter.visualState(of: row).isDeleted)
    }
}
