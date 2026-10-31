//
//  DataGridDisplayCacheTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
private final class DisplayGrid {
    let owner: GridTestOwner
    let model: DataGridModel
    let presenter: DataGridCellPresenter

    init(_ rows: TableRows) {
        owner = GridTestOwner(rows)
        model = DataGridModel()
        model.dataSource = owner
        model.actions = owner
        owner.model = model
        model.reloadRows()
        presenter = DataGridCellPresenter(model: model)
    }

    func text(row displayRow: Int, column position: Int = 0) -> String? {
        DataGridDisplayCacheTests.text(of: model, presenter: presenter, row: displayRow, column: position)
    }
}

@MainActor
struct DataGridDisplayCacheTests {
    private static let binary = Data([
        0xAF, 0x49, 0x45, 0x3B, 0x7F, 0x2F, 0xFB, 0x58,
        0xFC, 0xD3, 0x2B, 0xD3, 0x99, 0x59, 0x9F, 0xA5,
    ])
    private static let rawBinaryText = "0xAF49453B7F2FFB58FCD32BD399599FA5"
    private static let uuidText = "af49453b-7f2f-fb58-fcd3-2bd399599fa5"

    private static var binaryRows: TableRows {
        TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(binary)])],
            columns: ["id"],
            columnTypes: [.blob(rawType: "BLOB")]
        )
    }

    static func text(of model: DataGridModel, presenter: DataGridCellPresenter, row displayRow: Int, column position: Int) -> String? {
        guard let row = model.row(at: displayRow), let column = model.columns.column(at: position) else { return nil }
        return presenter.displayText(
            of: row,
            dataIndex: column.dataIndex,
            type: column.type,
            formats: model.store.displayFormats,
            databaseType: model.configuration.traits.databaseType,
            columnCount: model.rows.columns.count
        )
    }

    @Test("A row's cached text is served until the change to it reaches the model")
    func cacheServesTheRowUntilTheChangeArrives() {
        let grid = DisplayGrid(TableRows(
            rows: [Row(id: .existing(0), values: [.text("A")])],
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        ))
        #expect(grid.text(row: 0) == "A")

        grid.owner.tableRows.rows[0].values[0] = .text("B")
        #expect(grid.text(row: 0) == "A")

        grid.model.apply(.cellChanged(row: 0, column: 0))

        #expect(grid.text(row: 0) == "B")
    }

    @Test("A reload drops every cached text")
    func reloadDropsTheCache() {
        let grid = DisplayGrid(TableRows(
            rows: [Row(id: .existing(0), values: [.text("A")]), Row(id: .existing(1), values: [.text("C")])],
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        ))
        #expect(grid.text(row: 0) == "A")
        #expect(grid.text(row: 1) == "C")

        grid.owner.tableRows.rows[0].values[0] = .text("B")
        grid.owner.tableRows.rows[1].values[0] = .text("D")
        grid.model.reloadRows()

        #expect(grid.text(row: 0) == "B")
        #expect(grid.text(row: 1) == "D")
    }

    @Test("A display format change recomputes cached binary values")
    func displayFormatChangesRecomputeBinaryValues() throws {
        let grid = DisplayGrid(Self.binaryRows)
        let column = try #require(grid.model.columns.column(at: 0))
        #expect(grid.text(row: 0) == Self.rawBinaryText)

        grid.model.setDisplayFormat(.uuid, for: column)
        #expect(grid.text(row: 0) == Self.uuidText)

        grid.model.setDisplayFormat(.raw, for: column)
        #expect(grid.text(row: 0) == Self.rawBinaryText)
    }

    @Test("A schema this Mac lost, chosen again, redraws the cells it left as hex and carries their value filter over")
    func schemaReturnsToTheGrid() async throws {
        let grid = DisplayGrid(Self.binaryRows)
        let column = try #require(grid.model.columns.column(at: 0))
        let text = #"{"type":"fixed","name":"F"# + UUID().uuidString.filter(\.isLetter) + #"","size":16}"#
        grid.model.setDisplayFormat(.avro(schemaID: AvroSchemaStore.schemaID(of: text)), for: column)
        #expect(grid.text(row: 0) == Self.rawBinaryText)
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: [Self.rawBinaryText], includesNull: false), columnName: "id", forColumn: 0)
        grid.model.setValueFilter(filter)

        _ = try AvroSchemaStore.shared.add(text)

        let decoded = "\"" + Self.rawBinaryText + "\""
        try await waitUntil { grid.text(row: 0) == decoded }
        #expect(grid.model.store.valueFilter.filter(forColumn: 0)?.selectedValues == [decoded])
        #expect(grid.model.rowCount == 1)
    }

    @Test("A display format is kept in the grid's store, where its owner reads it")
    func displayFormatIsWrittenToTheStore() throws {
        let grid = DisplayGrid(Self.binaryRows)
        let column = try #require(grid.model.columns.column(at: 0))

        grid.model.setDisplayFormat(.uuid, for: column)

        #expect(grid.model.store.displayFormats == [.uuid])
        #expect(grid.model.displayFormat(for: column) == .uuid)
    }

    @Test("Reformatting for a settings change keeps a manual display format")
    func reformattingKeepsAManualFormat() throws {
        let hosted = HostedDataGrid(rows: Self.binaryRows)
        defer { hosted.close() }
        let column = try #require(hosted.model.columns.column(at: 0))
        hosted.model.setDisplayFormat(.uuid, for: column)

        hosted.controller.reformatText()

        #expect(hosted.model.store.displayFormats == [.uuid])
        let text = Self.text(of: hosted.model, presenter: hosted.controller.presenter, row: 0, column: 0)
        #expect(text == Self.uuidText)
    }

    @Test("The background prewarm formats the rows around the viewport and no further")
    func prewarmCachesAroundTheViewport() async throws {
        let rowCount = DataGridPrewarmWindow.margin * 3
        let rows = TableRows.from(
            queryRows: (0..<rowCount).map { [PluginCellValue.text("row \($0)")] },
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let hosted = HostedDataGrid(rows: rows)
        defer { hosted.close() }
        let cache = hosted.model.display.cache
        let edge = RowID.existing(DataGridPrewarmWindow.margin)

        try await waitUntil { cache.box(forID: edge) != nil }

        #expect(cache.box(forID: .existing(rowCount - 1)) == nil)
    }
}
