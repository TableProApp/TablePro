//
//  TableRowsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TableRows - construction")
struct TableRowsConstructionTests {
    @Test("Default initializer produces an empty table")
    func emptyByDefault() {
        let table = TableRows()
        #expect(table.rows.isEmpty)
        #expect(table.columns.isEmpty)
        #expect(table.columnTypes.isEmpty)
    }

    @Test("Factory with empty rows preserves columns and metadata")
    func factoryWithEmptyRows() {
        let table = TableRows.from(
            queryRows: [],
            columns: ["a"],
            columnTypes: [.text(rawType: nil)]
        )
        #expect(table.rows.isEmpty)
        #expect(table.columns == ["a"])
        #expect(table.columnTypes.count == 1)
    }

    @Test("Factory assigns ascending existing IDs to fresh rows")
    func factoryAssignsExistingIDs() {
        let table = TableRows.from(
            queryRows: [["1"], ["2"]],
            columns: ["id"],
            columnTypes: [.text(rawType: nil)]
        )
        #expect(table.count == 2)
        #expect(table.rows[0].id == .existing(0))
        #expect(table.rows[1].id == .existing(1))
        #expect(table.rows[0].values == ["1"])
        #expect(table.rows[1].values == ["2"])
    }

    @Test("Factory pads short rows and truncates long rows to columns.count")
    func factoryNormalizesRowWidth() {
        let table = TableRows.from(
            queryRows: [["a"], ["b", "c", "extra"]],
            columns: ["c1", "c2"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        #expect(table.count == 2)
        #expect(table.rows[0].values == ["a", nil])
        #expect(table.rows[1].values == ["b", "c"])
    }
}

@Suite("TableRows - reads")
struct TableRowsReadTests {
    @Test("value(at:column:) returns the cell at a valid coordinate")
    func valueAtValidCoordinate() {
        let table = TableRows.from(
            queryRows: [["a", "b"]],
            columns: ["c1", "c2"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        #expect(table.value(at: 0, column: 0) == "a")
        #expect(table.value(at: 0, column: 1) == "b")
    }

    @Test("value(at:column:) returns nil for out-of-bounds row")
    func valueAtOutOfBoundsRow() {
        let table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        #expect(table.value(at: 99, column: 0) == nil)
    }
}

@Suite("TableRows - id lookup")
struct TableRowsIDLookupTests {
    @Test("index(of:) returns the storage index for an existing RowID")
    func indexOfExistingRowID() {
        let table = TableRows.from(
            queryRows: [["a"], ["b"], ["c"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        #expect(table.index(of: .existing(0)) == 0)
        #expect(table.index(of: .existing(1)) == 1)
        #expect(table.index(of: .existing(2)) == 2)
    }

    @Test("index(of:) returns nil for an unknown RowID")
    func indexOfUnknownRowID() {
        let table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        #expect(table.index(of: .existing(99)) == nil)
        #expect(table.index(of: .inserted(UUID())) == nil)
    }

    @Test("index(of:) tracks inserted rows by their UUID after appendInsertedRow")
    func indexOfInsertedRow() {
        var table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        _ = table.appendInsertedRow(values: ["new"])
        let insertedID = table.rows[1].id
        #expect(table.index(of: insertedID) == 1)
    }

    @Test("index(of:) reflects shifted positions after insertInsertedRow at the head")
    func indexOfShiftsAfterHeadInsert() {
        var table = TableRows.from(
            queryRows: [["a"], ["b"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let originalID = table.rows[0].id
        _ = table.insertInsertedRow(at: 0, values: ["z"])
        #expect(table.index(of: originalID) == 1)
    }

    @Test("index(of:) reflects shifted positions after remove")
    func indexOfShiftsAfterRemove() {
        var table = TableRows.from(
            queryRows: [["a"], ["b"], ["c"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        _ = table.remove(at: IndexSet(integer: 0))
        #expect(table.index(of: .existing(0)) == nil)
        #expect(table.index(of: .existing(1)) == 0)
        #expect(table.index(of: .existing(2)) == 1)
    }

    @Test("row(withID:) returns the matching Row for an existing ID")
    func rowWithIDReturnsMatch() {
        let table = TableRows.from(
            queryRows: [["a"], ["b"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let row = table.row(withID: .existing(1))
        #expect(row?.values == ["b"])
        #expect(row?.id == .existing(1))
    }

    @Test("row(withID:) returns nil for an unknown ID")
    func rowWithIDReturnsNilForUnknown() {
        let table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        #expect(table.row(withID: .existing(99)) == nil)
    }

    @Test("row(withID:) reads back an inserted row by its UUID")
    func rowWithIDReturnsInsertedRow() {
        var table = TableRows.from(
            queryRows: [],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        _ = table.appendInsertedRow(values: ["v"])
        let insertedID = table.rows[0].id
        #expect(table.row(withID: insertedID)?.values == ["v"])
    }
}

@Suite("TableRows - edit")
struct TableRowsEditTests {
    private static func makeTable() -> TableRows {
        TableRows.from(
            queryRows: [["a", "b"], ["c", "d"]],
            columns: ["c1", "c2"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
    }

    @Test("edit returns cellChanged with the position and updates the cell")
    func editReturnsCellChanged() {
        var table = Self.makeTable()
        let delta = table.edit(row: 0, column: 0, value: "x")
        #expect(delta == .cellChanged(row: 0, column: 0))
        #expect(table.value(at: 0, column: 0) == "x")
    }

    @Test("edit with the same value returns Delta.none")
    func editSameValueIsNoOp() {
        var table = Self.makeTable()
        let delta = table.edit(row: 0, column: 0, value: "a")
        #expect(delta == .none)
        #expect(table.value(at: 0, column: 0) == "a")
    }

    @Test("edit with out-of-bounds row returns Delta.none and leaves rows untouched")
    func editOutOfBoundsRow() {
        var table = Self.makeTable()
        let delta = table.edit(row: 99, column: 0, value: "x")
        #expect(delta == .none)
        #expect(table.value(at: 0, column: 0) == "a")
    }

    @Test("editMany returns cellsChanged with one position per actual change")
    func editManyMultipleChanges() {
        var table = Self.makeTable()
        let delta = table.editMany([
            (row: 0, column: 0, value: "x"),
            (row: 0, column: 1, value: "y"),
            (row: 1, column: 0, value: "z")
        ])
        let expected: Set<CellPosition> = [
            CellPosition(row: 0, column: 0),
            CellPosition(row: 0, column: 1),
            CellPosition(row: 1, column: 0)
        ]
        #expect(delta == .cellsChanged(expected))
        #expect(table.value(at: 0, column: 0) == "x")
        #expect(table.value(at: 0, column: 1) == "y")
        #expect(table.value(at: 1, column: 0) == "z")
    }

    @Test("editMany returns Delta.none when all edits are no-ops")
    func editManyNoOpReturnsNone() {
        var table = Self.makeTable()
        let delta = table.editMany([
            (row: 0, column: 0, value: "a"),
            (row: 1, column: 1, value: "d")
        ])
        #expect(delta == .none)
    }

    @Test("editMany skips no-op edits and reports only actual changes")
    func editManyMixesValidAndNoOp() {
        var table = Self.makeTable()
        let delta = table.editMany([
            (row: 0, column: 0, value: "a"),
            (row: 0, column: 1, value: "y"),
            (row: 99, column: 0, value: "ignored"),
            (row: 0, column: 99, value: "ignored")
        ])
        let expected: Set<CellPosition> = [CellPosition(row: 0, column: 1)]
        #expect(delta == .cellsChanged(expected))
        #expect(table.value(at: 0, column: 1) == "y")
    }
}

@Suite("TableRows - insert")
struct TableRowsInsertTests {
    @Test("appendInsertedRow on an empty table returns rowsInserted at index 0")
    func appendInsertedRowOnEmpty() {
        var table = TableRows.from(
            queryRows: [],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.appendInsertedRow(values: ["x"])
        #expect(delta == .rowsInserted(IndexSet(integer: 0)))
        #expect(table.count == 1)
    }

    @Test("appendInsertedRow assigns RowID.inserted to the new row")
    func appendInsertedRowGetsInsertedID() {
        var table = TableRows.from(
            queryRows: [],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        _ = table.appendInsertedRow(values: ["x"])
        #expect(table.rows[0].id.isInserted)
    }

    @Test("Two appendInsertedRow calls produce different RowID UUIDs")
    func appendInsertedRowProducesDistinctUUIDs() {
        var table = TableRows.from(
            queryRows: [],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        _ = table.appendInsertedRow(values: ["x"])
        _ = table.appendInsertedRow(values: ["y"])
        #expect(table.rows[0].id != table.rows[1].id)
    }

    @Test("appendInsertedRow pads short values and truncates long values to columns.count")
    func appendInsertedRowPadsAndTruncates() {
        var table = TableRows.from(
            queryRows: [],
            columns: ["c1", "c2", "c3"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
        )
        _ = table.appendInsertedRow(values: ["only-one"])
        _ = table.appendInsertedRow(values: ["a", "b", "c", "d"])
        #expect(table.rows[0].values == ["only-one", nil, nil])
        #expect(table.rows[1].values == ["a", "b", "c"])
    }

    @Test("insertInsertedRow at the head shifts existing rows down")
    func insertInsertedRowAtHead() {
        var table = TableRows.from(
            queryRows: [["a"], ["b"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.insertInsertedRow(at: 0, values: ["z"])
        #expect(delta == .rowsInserted(IndexSet(integer: 0)))
        #expect(table.count == 3)
        #expect(table.rows[0].values == ["z"])
        #expect(table.rows[0].id.isInserted)
        #expect(table.rows[1].values == ["a"])
        #expect(table.rows[2].values == ["b"])
    }

    @Test("insertInsertedRow in the middle preserves surrounding rows")
    func insertInsertedRowInMiddle() {
        var table = TableRows.from(
            queryRows: [["a"], ["b"], ["c"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.insertInsertedRow(at: 1, values: ["z"])
        #expect(delta == .rowsInserted(IndexSet(integer: 1)))
        #expect(table.count == 4)
        #expect(table.rows[0].values == ["a"])
        #expect(table.rows[1].values == ["z"])
        #expect(table.rows[1].id.isInserted)
        #expect(table.rows[2].values == ["b"])
        #expect(table.rows[3].values == ["c"])
    }

    @Test("insertInsertedRow at the tail (index == count) appends")
    func insertInsertedRowAtTail() {
        var table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.insertInsertedRow(at: table.count, values: ["z"])
        #expect(delta == .rowsInserted(IndexSet(integer: 1)))
        #expect(table.count == 2)
        #expect(table.rows[1].values == ["z"])
        #expect(table.rows[1].id.isInserted)
    }

    @Test("insertInsertedRow pads short values and truncates long values")
    func insertInsertedRowPadsAndTruncates() {
        var table = TableRows.from(
            queryRows: [],
            columns: ["c1", "c2", "c3"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
        )
        _ = table.insertInsertedRow(at: 0, values: ["only-one"])
        _ = table.insertInsertedRow(at: 1, values: ["a", "b", "c", "d"])
        #expect(table.rows[0].values == ["only-one", nil, nil])
        #expect(table.rows[1].values == ["a", "b", "c"])
    }

    @Test("insertInsertedRow with negative index returns Delta.none and does not mutate")
    func insertInsertedRowNegativeIndexIsNoOp() {
        var table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.insertInsertedRow(at: -1, values: ["z"])
        #expect(delta == .none)
        #expect(table.count == 1)
        #expect(table.rows[0].values == ["a"])
    }

    @Test("insertInsertedRow past the end returns Delta.none and does not mutate")
    func insertInsertedRowPastEndIsNoOp() {
        var table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.insertInsertedRow(at: 2, values: ["z"])
        #expect(delta == .none)
        #expect(table.count == 1)
        #expect(table.rows[0].values == ["a"])
    }

    @Test("Two insertInsertedRow calls produce different RowID UUIDs")
    func insertInsertedRowProducesDistinctUUIDs() {
        var table = TableRows.from(
            queryRows: [],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        _ = table.insertInsertedRow(at: 0, values: ["x"])
        _ = table.insertInsertedRow(at: 0, values: ["y"])
        #expect(table.rows[0].id != table.rows[1].id)
    }
}

@Suite("TableRows - appendPage")
struct TableRowsAppendPageTests {
    @Test("appendPage on empty table returns rowsInserted with the appended range")
    func appendPageOnEmpty() {
        var table = TableRows.from(
            queryRows: [],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.appendPage([["a"], ["b"]], startingAt: 0)
        #expect(delta == .rowsInserted(IndexSet(integersIn: 0...1)))
        #expect(table.rows[0].id == .existing(0))
        #expect(table.rows[1].id == .existing(1))
    }

    @Test("appendPage on a populated table appends at the end with the supplied offset")
    func appendPageOntoExisting() {
        var table = TableRows.from(
            queryRows: [["a"], ["b"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.appendPage([["c"]], startingAt: 5)
        #expect(delta == .rowsInserted(IndexSet(integer: 2)))
        #expect(table.rows[2].id == .existing(5))
    }

    @Test("appendPage with empty input returns Delta.none and does not mutate")
    func appendPageEmptyInputIsNoOp() {
        var table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.appendPage([], startingAt: 1)
        #expect(delta == .none)
        #expect(table.count == 1)
    }
}

@Suite("TableRows - remove")
struct TableRowsRemoveTests {
    private static func makeTable() -> TableRows {
        TableRows.from(
            queryRows: [["a"], ["b"], ["c"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
    }

    @Test("remove(rowIDs:) removes matching rows and returns rowsRemoved IndexSet")
    func removeByIDs() {
        var table = Self.makeTable()
        let delta = table.remove(rowIDs: [.existing(0), .existing(2)])
        #expect(delta == .rowsRemoved(IndexSet([0, 2])))
        #expect(table.count == 1)
        #expect(table.rows[0].values == ["b"])
    }

    @Test("remove(at:) removes in descending order without index drift")
    func removeAtIndicesNoDrift() {
        var table = Self.makeTable()
        let delta = table.remove(at: IndexSet([0, 2]))
        #expect(delta == .rowsRemoved(IndexSet([0, 2])))
        #expect(table.count == 1)
        #expect(table.rows[0].values == ["b"])
    }

    @Test("remove(rowIDs:) can target inserted rows by their UUID")
    func removeInsertedRowByID() {
        var table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        _ = table.appendInsertedRow(values: ["new"])
        let insertedID = table.rows[1].id
        let delta = table.remove(rowIDs: [insertedID])
        #expect(delta == .rowsRemoved(IndexSet(integer: 1)))
        #expect(table.count == 1)
        #expect(table.rows[0].values == ["a"])
    }

    @Test("remove(at:) silently drops out-of-bounds indices")
    func removeAtSilentlyDropsOutOfBounds() {
        var table = Self.makeTable()
        let delta = table.remove(at: IndexSet([1, 99]))
        #expect(delta == .rowsRemoved(IndexSet(integer: 1)))
        #expect(table.count == 2)
    }

    @Test("remove with no matching IDs returns Delta.none")
    func removeWithNoMatchesIsNoOp() {
        var table = Self.makeTable()
        let delta = table.remove(rowIDs: [.existing(99)])
        #expect(delta == .none)
        #expect(table.count == 3)
    }
}

@Suite("TableRows - replace")
struct TableRowsReplaceTests {
    @Test("replace returns fullReplace and rebuilds rows with existing IDs")
    func replaceReturnsFullReplace() {
        var table = TableRows.from(
            queryRows: [["a"], ["b"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.replace(rows: [["x"]], offset: 0)
        #expect(delta == .fullReplace)
        #expect(table.count == 1)
        #expect(table.rows[0].id == .existing(0))
        #expect(table.rows[0].values == ["x"])
    }

    @Test("replace with non-zero offset assigns existing IDs starting from offset")
    func replaceWithNonZeroOffsetAssignsExistingIDs() {
        var table = TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)]
        )
        let delta = table.replace(rows: [["x"], ["y"]], offset: 5)
        #expect(delta == .fullReplace)
        #expect(table.count == 2)
        #expect(table.rows[0].id == .existing(5))
        #expect(table.rows[1].id == .existing(6))
        #expect(table.rows[0].values == ["x"])
        #expect(table.rows[1].values == ["y"])
    }
}

@Suite("TableRows - metadata")
struct TableRowsMetadataTests {
    private static func makeTable() -> TableRows {
        TableRows.from(
            queryRows: [["a"]],
            columns: ["c1"],
            columnTypes: [.text(rawType: nil)],
            columnDefaults: ["c1": "d"],
            columnNullable: ["c1": true]
        )
    }

    @Test("updateDisplayMetadata reports columnsReplaced when a field changes")
    func updateDisplayMetadataDetectsChange() {
        var table = Self.makeTable()
        let delta = table.updateDisplayMetadata(columnTypes: [.integer(rawType: "INT")])
        #expect(delta == .columnsReplaced)
        #expect(table.columnTypes == [.integer(rawType: "INT")])
    }

    @Test("updateDisplayMetadata returns Delta.none when all arguments are nil")
    func updateDisplayMetadataAllNilIsNoOp() {
        var table = Self.makeTable()
        let delta = table.updateDisplayMetadata()
        #expect(delta == .none)
    }

    @Test("updateDisplayMetadata returns Delta.none when supplied values match current state")
    func updateDisplayMetadataEqualValuesIsNoOp() {
        var table = Self.makeTable()
        let delta = table.updateDisplayMetadata(
            columnTypes: [.text(rawType: nil)],
            columnDefaults: ["c1": "d"],
            columnNullable: ["c1": true]
        )
        #expect(delta == .none)
    }
}

@Suite("TableRows - metadata preservation regression")
struct TableRowsMetadataPreservationTests {
    private static func makeTable() -> TableRows {
        TableRows.from(
            queryRows: [["a", "b"], ["c", "d"]],
            columns: ["c1", "c2"],
            columnTypes: [.text(rawType: "TEXT"), .integer(rawType: "INT")],
            columnDefaults: ["c1": "default-1"],
            columnForeignKeys: ["c2": ForeignKeyInfo(name: "fk", column: "c2", referencedTable: "t", referencedColumn: "id")],
            columnEnumValues: ["c1": ["a", "b"]],
            columnNullable: ["c2": false]
        )
    }

    private static func assertMetadataPreserved(_ table: TableRows) {
        #expect(table.columnTypes == [.text(rawType: "TEXT"), .integer(rawType: "INT")])
        #expect(table.columnDefaults["c1"] == "default-1")
        #expect(table.columnForeignKeys["c2"]?.referencedTable == "t")
        #expect(table.columnEnumValues["c1"] == ["a", "b"])
        #expect(table.columnNullable["c2"] == false)
    }

    @Test("edit preserves all column metadata")
    func editPreservesMetadata() {
        var table = Self.makeTable()
        _ = table.edit(row: 0, column: 0, value: "x")
        Self.assertMetadataPreserved(table)
    }

    @Test("appendInsertedRow preserves all column metadata")
    func appendInsertedRowPreservesMetadata() {
        var table = Self.makeTable()
        _ = table.appendInsertedRow(values: ["x", "y"])
        Self.assertMetadataPreserved(table)
    }

    @Test("remove preserves all column metadata")
    func removePreservesMetadata() {
        var table = Self.makeTable()
        _ = table.remove(at: IndexSet(integer: 0))
        Self.assertMetadataPreserved(table)
    }

    @Test("replace preserves all column metadata")
    func replacePreservesMetadata() {
        var table = Self.makeTable()
        _ = table.replace(rows: [["x", "y"]], offset: 0)
        Self.assertMetadataPreserved(table)
    }
}
