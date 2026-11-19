//
//  TableRowsSparseStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableRowsSparseStateTests {
    private static let columns = ["id", "name", "note"]
    private static let types = Array(repeating: ColumnType.text(rawType: nil), count: 3)

    private static func page(_ count: Int, offset: Int = 0) -> [[PluginCellValue]] {
        (0..<count).map { [.text(String(offset + $0)), .text("n\(offset + $0)"), .null] }
    }

    private static func ids(_ rows: TableRows) -> [RowID] {
        rows.rows.map(\.id)
    }

    // Every id resolves to where it sits, and nothing else resolves.
    private static func expectConsistent(_ rows: TableRows, sourceLocation: SourceLocation = #_sourceLocation) {
        for (position, row) in rows.rows.enumerated() {
            #expect(rows.index(of: row.id) == position, sourceLocation: sourceLocation)
        }
        #expect(rows.index(of: .existing(-1)) == nil, sourceLocation: sourceLocation)
        #expect(rows.index(of: .existing(Int.max)) == nil, sourceLocation: sourceLocation)
        #expect(rows.index(of: .inserted(UUID())) == nil, sourceLocation: sourceLocation)
    }

    @Test("A row holds its id and its values and nothing more")
    func rowIsItsIdAndValues() {
        #expect(MemoryLayout<Row>.stride == 32)
    }

    @Test("Rows read in order resolve by position, with nothing hashed")
    func orderedRowsHashNothing() {
        var rows = TableRows.from(queryRows: Self.page(500), columns: Self.columns, columnTypes: Self.types)
        rows.appendPage(Self.page(250, offset: 500), startingAt: 500)

        #expect(rows.hashedPositionCount == 0)
        #expect(rows.index(of: .existing(0)) == 0)
        #expect(rows.index(of: .existing(749)) == 749)
        #expect(rows.index(of: .existing(750)) == nil)
        Self.expectConsistent(rows)
    }

    @Test("A page that starts past zero resolves by position too")
    func offsetPageResolves() {
        let rows = TableRows.from(queryRows: Self.page(10), columns: Self.columns, columnTypes: Self.types)
        var shifted = TableRows(columns: Self.columns, columnTypes: Self.types)
        shifted.replace(rows: Self.page(10, offset: 300), offset: 300)

        #expect(shifted.hashedPositionCount == 0)
        #expect(shifted.index(of: .existing(300)) == 0)
        #expect(shifted.index(of: .existing(0)) == nil)
        #expect(rows.index(of: .existing(300)) == nil)
        Self.expectConsistent(shifted)
    }

    @Test("Added rows are the only ones hashed, and every row resolves after one is removed")
    func insertedRowsHashOnlyThemselves() {
        var rows = TableRows.from(queryRows: Self.page(20), columns: Self.columns, columnTypes: Self.types)
        let first = RowID.inserted(UUID())
        let second = RowID.inserted(UUID())
        rows.appendInsertedRow(id: first, values: [.text("a"), .null, .null])
        rows.appendInsertedRow(id: second, values: [.text("b"), .null, .null])

        #expect(rows.hashedPositionCount == 2)
        Self.expectConsistent(rows)

        rows.remove(rowIDs: [first])
        #expect(rows.index(of: first) == nil)
        #expect(rows.index(of: second) == 20)
        Self.expectConsistent(rows)

        rows.remove(rowIDs: [.existing(3), .existing(7)])
        #expect(rows.count == 19)
        #expect(rows.index(of: .existing(3)) == nil)
        Self.expectConsistent(rows)
    }

    @Test("A row added in the middle moves every row after it")
    func insertingInTheMiddleMovesLaterRows() {
        var rows = TableRows.from(queryRows: Self.page(10), columns: Self.columns, columnTypes: Self.types)
        let added = RowID.inserted(UUID())
        rows.insertInsertedRow(at: 4, id: added, values: [.text("x"), .null, .null])

        #expect(rows.index(of: added) == 4)
        #expect(rows.index(of: .existing(4)) == 5)
        Self.expectConsistent(rows)
    }

    @Test("A repeated id resolves to its last row, as a dictionary index did")
    func repeatedIdResolvesToTheLastRow() {
        let rows = TableRows(
            rows: [Row(id: .existing(0), values: ["a"]), Row(id: .existing(1), values: ["b"]), Row(id: .existing(0), values: ["c"])],
            columns: ["v"],
            columnTypes: [.text(rawType: nil)]
        )

        #expect(rows.index(of: .existing(0)) == 2)
        #expect(rows.index(of: .existing(1)) == 1)
    }

    @Test("Missing fields, unloaded values and export documents follow their row through a reorder")
    func sparseStateFollowsItsRow() {
        let document = PluginExportDocument(fields: [], bsonSizeUpperBound: nil)
        var rows = TableRows.from(
            queryRows: Self.page(4),
            columns: Self.columns,
            columnTypes: Self.types,
            exportDocuments: Array(repeating: document, count: 4),
            absentCells: [1: [2]],
            unloadedCells: [2: [1: 9_000]]
        )

        rows.reorderRows(ContiguousArray(rows.rows.reversed()))

        #expect(rows.isAbsent(row: 2, column: 2))
        #expect(!rows.isAbsent(row: 1, column: 2))
        #expect(rows.unloadedByteCount(row: 1, column: 1) == 9_000)
        #expect(rows.unloadedByteCount(row: 2, column: 1) == nil)
        #expect(rows.absentColumns(of: .existing(1)) == [2])
        #expect(rows.rowIDsWithUnloadedValues == [.existing(2)])
        #expect(rows.exportDocument(of: rows.rows[0]) == document)
        Self.expectConsistent(rows)
    }

    @Test("A removed row takes its sparse state with it")
    func removalDropsSparseState() {
        var rows = TableRows.from(
            queryRows: Self.page(3),
            columns: Self.columns,
            columnTypes: Self.types,
            absentCells: [1: [2]],
            unloadedCells: [1: [1: 10]]
        )

        rows.remove(rowIDs: [.existing(1)])

        #expect(!rows.hasUnloadedValues)
        #expect(rows.absentColumns(of: .existing(1)).isEmpty)
        #expect(rows.absentColumnsByRow.isEmpty)
    }

    @Test("Writing a cell loads it and restores a removed field")
    func writingClearsUnloadedAndAbsent() {
        var rows = TableRows.from(
            queryRows: Self.page(2),
            columns: Self.columns,
            columnTypes: Self.types,
            absentCells: [0: [2]],
            unloadedCells: [0: [1: 10]]
        )

        #expect(rows.edit(row: 0, column: 1, value: .text("typed")) == .cellChanged(row: 0, column: 1))
        #expect(rows.unloadedByteCount(row: 0, column: 1) == nil)
        #expect(!rows.hasUnloadedValues)

        rows.edit(row: 0, column: 2, value: .text("now here"))
        #expect(!rows.isAbsent(row: 0, column: 2))

        rows.edit(row: 1, column: 2, value: .null, isAbsent: true)
        #expect(rows.isAbsent(row: 1, column: 2))
        #expect(rows.absentColumns(of: .existing(1)) == [2])
    }

    @Test("Loaded values fill only the cells still waiting on the server")
    func fillingUnloadedValues() {
        var rows = TableRows.from(
            queryRows: Self.page(2),
            columns: Self.columns,
            columnTypes: Self.types,
            unloadedCells: [1: [1: 10, 2: 20]]
        )

        let delta = rows.fillUnloaded([.existing(1): [1: .text("loaded")], .existing(0): [1: .text("ignored")]])

        #expect(delta == .cellsChanged([CellPosition(row: 1, column: 1)]))
        #expect(rows.value(at: 1, column: 1) == .text("loaded"))
        #expect(rows.value(at: 0, column: 1) == .text("n0"))
        #expect(rows.unloadedColumns(of: .existing(1)) == [2: 20])
        #expect(rows.hasUnloadedValues(.existing(1)))
    }

    @Test("A released result keeps its columns and drops its rows")
    func releasingRowsKeepsTheShape() {
        var rows = TableRows.from(queryRows: Self.page(3), columns: Self.columns, columnTypes: Self.types, absentCells: [0: [1]])
        let shared = rows

        #expect(rows.sharesRows(with: shared))
        rows.releaseRows()

        #expect(rows.rows.isEmpty)
        #expect(rows.columns == Self.columns)
        #expect(rows.index(of: .existing(0)) == nil)
        #expect(rows.absentColumnsByRow.isEmpty)
        #expect(!rows.sharesRows(with: shared))
    }
}
