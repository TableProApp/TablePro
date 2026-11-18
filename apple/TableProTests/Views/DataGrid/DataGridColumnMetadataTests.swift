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
