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

    private static func twoRows() -> TableRows {
        TableRows(
            rows: [Row(id: .existing(0), values: [.text("A")]), Row(id: .existing(1), values: [.text("C")])],
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )
    }

    @Test("Text formatted before an edit landed is thrown away")
    func prewarmDropsTextAnEditOutdated() async throws {
        let grid = DisplayGrid(Self.twoRows())
        let walk = try #require(grid.presenter.prewarmBatch(in: 0..<2, from: 0))
        let batch = try #require(walk.batch)
        let formatted = await batch.formatted()

        grid.owner.tableRows.rows[0].values[0] = .text("B")
        grid.model.apply(.cellChanged(row: 0, column: 0))

        #expect(!grid.presenter.installPrewarmed(formatted, of: batch))
        #expect(grid.model.display.cache.box(forID: .existing(1)) == nil)
        #expect(grid.text(row: 0) == "B")
    }

    @Test("A row drawn while its batch formatted keeps the text it drew")
    func prewarmLeavesARowDrawnMeanwhile() async throws {
        let grid = DisplayGrid(Self.twoRows())
        let walk = try #require(grid.presenter.prewarmBatch(in: 0..<2, from: 0))
        let batch = try #require(walk.batch)
        let formatted = await batch.formatted()

        #expect(grid.text(row: 0) == "A")
        let drawn = grid.model.display.cache.box(forID: .existing(0))

        #expect(grid.presenter.installPrewarmed(formatted, of: batch))
        #expect(grid.model.display.cache.box(forID: .existing(0)) === drawn)
        #expect(grid.model.display.cache.box(forID: .existing(1))?.values[0] == "C")
    }

    @Test("The prewarm formats a cut text's first characters, as the draw does")
    func prewarmShowsCutTextHead() async throws {
        let grid = DisplayGrid(TableRows.from(
            queryRows: [[.text("lorem ipsum")], [.text("dolor")]],
            columns: ["body"],
            columnTypes: [.text(rawType: "LONGTEXT")],
            unloadedCells: [0: [0: 5_242_880]]
        ))
        let walk = try #require(grid.presenter.prewarmBatch(in: 0..<2, from: 0))
        let batch = try #require(walk.batch)
        let formatted = await batch.formatted()

        #expect(grid.presenter.installPrewarmed(formatted, of: batch))
        #expect(grid.model.display.cache.box(forID: .existing(0))?.values[0] == "lorem ipsum")
        #expect(grid.model.display.cache.box(forID: .existing(1))?.values[0] == "dolor")
    }

    @Test("A batch copies only rows with no text yet, and stops at its limit")
    func prewarmBatchSkipsCachedRows() throws {
        let rowCount = DataGridPrewarmBatch.rowLimit * 2
        let grid = DisplayGrid(TableRows.from(
            queryRows: (0..<rowCount).map { [PluginCellValue.text("row \($0)")] },
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        ))
        #expect(grid.text(row: 0) == "row 0")

        let walk = try #require(grid.presenter.prewarmBatch(in: 0..<rowCount, from: 0))
        let batch = try #require(walk.batch)

        #expect(batch.rows.count == DataGridPrewarmBatch.rowLimit)
        #expect(batch.rows.first?.id == .existing(1))
        #expect(walk.next == DataGridPrewarmBatch.rowLimit + 1)
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
