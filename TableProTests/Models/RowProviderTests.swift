//
//  RowProviderTests.swift
//  TableProTests
//
//  Tests for TableRowData and InMemoryRowProvider
//

import Foundation
import Testing
@testable import TablePro

// MARK: - TableRowData Tests

@Suite("TableRowData")
struct TableRowDataTests {
    @Test("Stores index and values")
    func storesIndexAndValues() {
        let row = TableRowData(index: 5, values: ["a", "b", "c"])
        #expect(row.index == 5)
        #expect(row.values == ["a", "b", "c"])
    }

    @Test("value(at:) returns value at valid index")
    func valueAtValid() {
        let row = TableRowData(index: 0, values: ["hello", "world"])
        #expect(row.value(at: 0) == "hello")
        #expect(row.value(at: 1) == "world")
    }

    @Test("value(at:) returns value at last index")
    func valueAtLast() {
        let row = TableRowData(index: 0, values: ["a", "b", "c"])
        #expect(row.value(at: 2) == "c")
    }

    @Test("value(at:) returns nil for out-of-bounds index")
    func valueAtOutOfBounds() {
        let row = TableRowData(index: 0, values: ["a"])
        #expect(row.value(at: 1) == nil)
        #expect(row.value(at: 100) == nil)
    }

    @Test("value(at:) returns nil for nil entry")
    func valueAtNilEntry() {
        let row = TableRowData(index: 0, values: [nil, "b"])
        #expect(row.value(at: 0) == nil)
    }

    @Test("setValue at valid index updates value")
    func setValueValid() {
        let row = TableRowData(index: 0, values: ["old", "keep"])
        row.setValue("new", at: 0)
        #expect(row.value(at: 0) == "new")
        #expect(row.value(at: 1) == "keep")
    }

    @Test("setValue to nil clears value")
    func setValueNil() {
        let row = TableRowData(index: 0, values: ["hello"])
        row.setValue(nil, at: 0)
        #expect(row.value(at: 0) == nil)
    }

    @Test("setValue out-of-bounds is no-op")
    func setValueOutOfBounds() {
        let row = TableRowData(index: 0, values: ["a"])
        row.setValue("b", at: 5)
        #expect(row.values == ["a"])
    }

    @Test("Empty values array")
    func emptyValues() {
        let row = TableRowData(index: 0, values: [])
        #expect(row.values.isEmpty)
        #expect(row.value(at: 0) == nil)
    }

    @Test("Index is immutable after setValue")
    func indexImmutable() {
        let row = TableRowData(index: 42, values: ["x"])
        row.setValue("y", at: 0)
        #expect(row.index == 42)
    }

    @Test("Values array is mutable")
    func valuesMutable() {
        let row = TableRowData(index: 0, values: ["a", "b"])
        row.values[0] = "z"
        #expect(row.values[0] == "z")
    }

    @Test("Reference semantics - two refs see same mutation")
    func referenceSemantics() {
        let row = TableRowData(index: 0, values: ["a"])
        let ref = row
        ref.setValue("b", at: 0)
        #expect(row.value(at: 0) == "b")
    }
}

// MARK: - InMemoryRowProvider Tests

@Suite("InMemoryRowProvider")
struct InMemoryRowProviderTests {
    // MARK: - Init

    @Test("Init stores rows and columns")
    func initStoresRowsAndColumns() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        #expect(provider.totalRowCount == 3)
        #expect(provider.columns == ["id", "name", "email"])
    }

    @Test("Init with empty rows")
    func initEmptyRows() {
        let provider = InMemoryRowProvider(rows: [], columns: ["a"])
        #expect(provider.totalRowCount == 0)
        #expect(provider.columns == ["a"])
    }

    @Test("Init with column defaults")
    func initColumnDefaults() {
        let provider = InMemoryRowProvider(
            rows: [], columns: ["id", "status"],
            columnDefaults: ["status": "active"]
        )
        #expect(provider.columnDefaults["status"] as? String == "active")
    }

    @Test("Init with explicit column types")
    func initExplicitTypes() {
        let types: [ColumnType] = [.integer(rawType: "INT"), .text(rawType: "VARCHAR")]
        let provider = InMemoryRowProvider(rows: [], columns: ["id", "name"], columnTypes: types)
        #expect(provider.columnTypes == types)
    }

    @Test("Init with nil types defaults to text")
    func initNilTypesDefault() {
        let provider = InMemoryRowProvider(rows: [], columns: ["a", "b"])
        #expect(provider.columnTypes.count == 2)
        #expect(provider.columnTypes[0] == .text(rawType: nil))
        #expect(provider.columnTypes[1] == .text(rawType: nil))
    }

    // MARK: - Metadata

    @Test("Foreign key access")
    func foreignKeyAccess() {
        let fk = TestFixtures.makeForeignKeyInfo()
        let provider = InMemoryRowProvider(rows: [], columns: ["user_id"], columnForeignKeys: ["user_id": fk])
        #expect(provider.columnForeignKeys["user_id"]?.name == "fk_user")
    }

    @Test("Enum values access")
    func enumValuesAccess() {
        let provider = InMemoryRowProvider(
            rows: [], columns: ["status"],
            columnEnumValues: ["status": ["active", "inactive"]]
        )
        #expect(provider.columnEnumValues["status"] == ["active", "inactive"])
    }

    @Test("Nullable info access")
    func nullableInfoAccess() {
        let provider = InMemoryRowProvider(rows: [], columns: ["name"], columnNullable: ["name": true])
        #expect(provider.columnNullable["name"] == true)
    }

    @Test("Empty metadata defaults")
    func emptyMetadataDefaults() {
        let provider = InMemoryRowProvider(rows: [], columns: ["a"])
        #expect(provider.columnForeignKeys.isEmpty)
        #expect(provider.columnEnumValues.isEmpty)
        #expect(provider.columnNullable.isEmpty)
        #expect(provider.columnDefaults.isEmpty)
    }

    @Test("totalRowCount matches source rows")
    func totalRowCountMatches() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 7)
        #expect(provider.totalRowCount == 7)
    }

    // MARK: - row(at:)

    @Test("row(at:) returns data for valid index")
    func rowAtValid() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        let row = provider.row(at: 0)
        #expect(row != nil)
        #expect(row?.index == 0)
        #expect(row?.value(at: 0) == "id_0")
    }

    @Test("row(at:) returns data for last index")
    func rowAtLast() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 5)
        let row = provider.row(at: 4)
        #expect(row != nil)
        #expect(row?.index == 4)
    }

    @Test("row(at:) returns nil for negative index")
    func rowAtNegative() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        #expect(provider.row(at: -1) == nil)
    }

    @Test("row(at:) returns nil for out-of-bounds index")
    func rowAtOutOfBounds() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        #expect(provider.row(at: 3) == nil)
        #expect(provider.row(at: 100) == nil)
    }

    // MARK: - fetchRows

    @Test("fetchRows returns full range")
    func fetchRowsFullRange() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 5)
        let rows = provider.fetchRows(offset: 0, limit: 5)
        #expect(rows.count == 5)
        #expect(rows[0].index == 0)
        #expect(rows[4].index == 4)
    }

    @Test("fetchRows returns partial range")
    func fetchRowsPartialRange() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 10)
        let rows = provider.fetchRows(offset: 2, limit: 3)
        #expect(rows.count == 3)
        #expect(rows[0].index == 2)
        #expect(rows[2].index == 4)
    }

    @Test("fetchRows with zero limit returns empty")
    func fetchRowsZeroLimit() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 5)
        let rows = provider.fetchRows(offset: 0, limit: 0)
        #expect(rows.isEmpty)
    }

    @Test("fetchRows offset beyond count returns empty")
    func fetchRowsOffsetBeyond() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        let rows = provider.fetchRows(offset: 10, limit: 5)
        #expect(rows.isEmpty)
    }

    @Test("fetchRows limit exceeds available returns available")
    func fetchRowsLimitExceeds() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        let rows = provider.fetchRows(offset: 0, limit: 100)
        #expect(rows.count == 3)
    }

    @Test("fetchRows from middle of data")
    func fetchRowsFromMiddle() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 10)
        let rows = provider.fetchRows(offset: 5, limit: 3)
        #expect(rows.count == 3)
        #expect(rows[0].index == 5)
    }

    @Test("fetchRows preserves data order")
    func fetchRowsPreservesOrder() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 5)
        let rows = provider.fetchRows(offset: 0, limit: 5)
        for (i, row) in rows.enumerated() {
            #expect(row.index == i)
            #expect(row.value(at: 0) == "id_\(i)")
        }
    }

    @Test("fetchRows on empty provider returns empty")
    func fetchRowsEmpty() {
        let provider = InMemoryRowProvider(rows: [], columns: ["a"])
        let rows = provider.fetchRows(offset: 0, limit: 10)
        #expect(rows.isEmpty)
    }

    // MARK: - updateValue

    @Test("updateValue changes value")
    func updateValueChanges() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.updateValue("updated", at: 1, columnIndex: 0)
        #expect(provider.value(atRow: 1, column: 0) == "updated")
    }

    @Test("updateValue sets value to nil")
    func updateValueNil() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.updateValue(nil, at: 0, columnIndex: 1)
        #expect(provider.value(atRow: 0, column: 1) == nil)
    }

    @Test("updateValue out-of-bounds row is no-op")
    func updateValueOutOfBounds() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.updateValue("x", at: 10, columnIndex: 0)
        #expect(provider.totalRowCount == 3)
    }

    @Test("updateValue reflects in direct access")
    func updateValueReflectsInDirectAccess() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        #expect(provider.value(atRow: 0, column: 0) == "id_0")
        provider.updateValue("changed", at: 0, columnIndex: 0)
        #expect(provider.value(atRow: 0, column: 0) == "changed")
    }

    // MARK: - appendRow

    @Test("appendRow increases count")
    func appendRowCount() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 2)
        let _ = provider.appendRow(values: ["new1", "new2", "new3"])
        #expect(provider.totalRowCount == 3)
    }

    @Test("appendRow returns correct index")
    func appendRowIndex() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 5)
        let index = provider.appendRow(values: ["a", "b", "c"])
        #expect(index == 5)
    }

    @Test("Appended row is accessible via value(atRow:column:)")
    func appendRowAccessible() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 1)
        let index = provider.appendRow(values: ["x", "y", "z"])
        #expect(provider.value(atRow: index, column: 0) == "x")
        #expect(provider.value(atRow: index, column: 2) == "z")
    }

    @Test("Multiple appends work correctly")
    func multipleAppends() {
        let provider = InMemoryRowProvider(rows: [], columns: ["a"])
        let i1 = provider.appendRow(values: ["first"])
        let i2 = provider.appendRow(values: ["second"])
        let i3 = provider.appendRow(values: ["third"])
        #expect(i1 == 0)
        #expect(i2 == 1)
        #expect(i3 == 2)
        #expect(provider.totalRowCount == 3)
    }

    @Test("Append to empty provider")
    func appendToEmpty() {
        let provider = InMemoryRowProvider(rows: [], columns: ["col"])
        let index = provider.appendRow(values: ["val"])
        #expect(index == 0)
        #expect(provider.totalRowCount == 1)
        #expect(provider.value(atRow: 0, column: 0) == "val")
    }

    // MARK: - removeRow

    @Test("removeRow decreases count")
    func removeRowCount() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.removeRow(at: 1)
        #expect(provider.totalRowCount == 2)
    }

    @Test("removeRow out-of-bounds is no-op")
    func removeRowOutOfBounds() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.removeRow(at: 10)
        #expect(provider.totalRowCount == 3)
    }

    @Test("removeRow negative index is no-op")
    func removeRowNegative() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.removeRow(at: -1)
        #expect(provider.totalRowCount == 3)
    }

    // MARK: - removeRows

    @Test("removeRows removes multiple rows")
    func removeRowsMultiple() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 5)
        provider.removeRows(at: [1, 3])
        #expect(provider.totalRowCount == 3)
    }

    @Test("removeRows with empty set is no-op")
    func removeRowsEmpty() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.removeRows(at: [])
        #expect(provider.totalRowCount == 3)
    }

    @Test("removeRows skips invalid indices")
    func removeRowsSkipsInvalid() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.removeRows(at: [0, 10, 20])
        #expect(provider.totalRowCount == 2)
    }

    @Test("removeRows can remove all")
    func removeRowsAll() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.removeRows(at: [0, 1, 2])
        #expect(provider.totalRowCount == 0)
    }

    // MARK: - invalidateCache

    @Test("invalidateCache preserves data")
    func invalidateCachePreservesData() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.invalidateCache()
        #expect(provider.value(atRow: 0, column: 0) == "id_0")
        #expect(provider.totalRowCount == 3)
    }

    // MARK: - updateRows

    @Test("updateRows replaces all data")
    func updateRowsReplaces() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        let newRows = [QueryResultRow(id: 0, values: ["new_a", "new_b", "new_c"])]
        provider.updateRows(newRows)
        #expect(provider.totalRowCount == 1)
        #expect(provider.value(atRow: 0, column: 0) == "new_a")
    }

    @Test("updateRows with empty array sets count to 0")
    func updateRowsEmpty() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 5)
        provider.updateRows([])
        #expect(provider.totalRowCount == 0)
    }

    // MARK: - Direct Access Methods

    @Test("value(atRow:column:) returns correct value")
    func valueAtRowColumn() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        #expect(provider.value(atRow: 0, column: 0) == "id_0")
        #expect(provider.value(atRow: 1, column: 1) == "name_1")
        #expect(provider.value(atRow: 2, column: 2) == "email_2")
    }

    @Test("value(atRow:column:) returns nil for out-of-bounds row")
    func valueAtRowOutOfBounds() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        #expect(provider.value(atRow: -1, column: 0) == nil)
        #expect(provider.value(atRow: 3, column: 0) == nil)
    }

    @Test("value(atRow:column:) returns nil for out-of-bounds column")
    func valueAtColumnOutOfBounds() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        #expect(provider.value(atRow: 0, column: -1) == nil)
        #expect(provider.value(atRow: 0, column: 100) == nil)
    }

    @Test("rowValues(at:) returns correct array")
    func rowValuesAt() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        let values = provider.rowValues(at: 1)
        #expect(values == ["id_1", "name_1", "email_1"])
    }

    @Test("rowValues(at:) returns nil for out-of-bounds")
    func rowValuesAtOutOfBounds() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        #expect(provider.rowValues(at: -1) == nil)
        #expect(provider.rowValues(at: 3) == nil)
    }

    @Test("value(atRow:column:) reflects updateValue")
    func valueReflectsUpdate() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 3)
        provider.updateValue("changed", at: 1, columnIndex: 0)
        #expect(provider.value(atRow: 1, column: 0) == "changed")
    }

    @Test("rowValues(at:) reflects appendRow")
    func rowValuesReflectsAppend() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 2)
        let index = provider.appendRow(values: ["a", "b", "c"])
        let values = provider.rowValues(at: index)
        #expect(values == ["a", "b", "c"])
    }

    @Test("Large row count direct access works")
    func largeRowCountDirectAccess() {
        let provider = TestFixtures.makeInMemoryRowProvider(rowCount: 10000)
        #expect(provider.value(atRow: 0, column: 0) == "id_0")
        #expect(provider.value(atRow: 9999, column: 0) == "id_9999")
        #expect(provider.totalRowCount == 10000)
    }
}
