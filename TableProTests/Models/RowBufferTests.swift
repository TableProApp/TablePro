import Foundation
import Testing
@testable import TablePro

@Suite("RowBuffer")
struct RowBufferTests {
    // MARK: - Initialization

    @Test("Init with default values creates empty buffer")
    func initDefaults() {
        let buffer = RowBuffer()
        #expect(buffer.rows.isEmpty)
        #expect(buffer.columns.isEmpty)
        #expect(buffer.columnTypes.isEmpty)
        #expect(buffer.isEvicted == false)
    }

    @Test("Init with data preserves all fields")
    func initWithData() {
        let rows = TestFixtures.makeQueryResultRows(count: 5)
        let buffer = RowBuffer(
            rows: rows,
            columns: ["id", "name", "email"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR"), .text(rawType: "VARCHAR")]
        )
        #expect(buffer.rows.count == 5)
        #expect(buffer.columns == ["id", "name", "email"])
        #expect(buffer.columnTypes.count == 3)
        #expect(buffer.isEvicted == false)
    }

    // MARK: - Eviction

    @Test("evict() clears rows and sets isEvicted")
    func evictClearsRows() {
        let buffer = RowBuffer(rows: TestFixtures.makeQueryResultRows(count: 10), columns: ["a"])
        buffer.evict()
        #expect(buffer.rows.isEmpty)
        #expect(buffer.isEvicted == true)
    }

    @Test("evict() preserves column metadata")
    func evictPreservesMetadata() {
        let fk = TestFixtures.makeForeignKeyInfo()
        let buffer = RowBuffer(
            rows: TestFixtures.makeQueryResultRows(count: 3),
            columns: ["id", "user_id"],
            columnTypes: [.integer(rawType: "INT"), .integer(rawType: "INT")],
            columnDefaults: ["id": nil],
            columnForeignKeys: ["user_id": fk],
            columnEnumValues: ["status": ["a", "b"]],
            columnNullable: ["id": false]
        )
        buffer.evict()
        #expect(buffer.columns == ["id", "user_id"])
        #expect(buffer.columnTypes.count == 2)
        #expect(buffer.columnForeignKeys["user_id"]?.name == "fk_user")
        #expect(buffer.columnEnumValues["status"] == ["a", "b"])
        #expect(buffer.columnNullable["id"] == false)
    }

    @Test("Double evict is no-op")
    func doubleEvictNoOp() {
        let buffer = RowBuffer(rows: TestFixtures.makeQueryResultRows(count: 3), columns: ["a"])
        buffer.evict()
        buffer.evict()
        #expect(buffer.isEvicted == true)
        #expect(buffer.rows.isEmpty)
    }

    // MARK: - Restore

    @Test("restore() repopulates rows and clears isEvicted")
    func restoreRepopulates() {
        let buffer = RowBuffer(rows: TestFixtures.makeQueryResultRows(count: 3), columns: ["a"])
        buffer.evict()
        #expect(buffer.isEvicted == true)

        let newRows = TestFixtures.makeQueryResultRows(count: 5)
        buffer.restore(rows: newRows)
        #expect(buffer.rows.count == 5)
        #expect(buffer.isEvicted == false)
    }

    @Test("restore() with empty rows clears eviction flag")
    func restoreEmptyRows() {
        let buffer = RowBuffer(rows: TestFixtures.makeQueryResultRows(count: 3), columns: ["a"])
        buffer.evict()
        buffer.restore(rows: [])
        #expect(buffer.isEvicted == false)
        #expect(buffer.rows.isEmpty)
    }

    // MARK: - Copy

    @Test("copy() creates independent buffer")
    func copyCreatesIndependent() {
        let original = RowBuffer(rows: TestFixtures.makeQueryResultRows(count: 3), columns: ["a", "b"])
        let copied = original.copy()
        copied.rows.removeAll()
        #expect(original.rows.count == 3)
        #expect(copied.rows.isEmpty)
    }

    @Test("copy() preserves eviction state as false")
    func copyPreservesNonEvictedState() {
        let original = RowBuffer(rows: TestFixtures.makeQueryResultRows(count: 3), columns: ["a"])
        let copied = original.copy()
        #expect(copied.isEvicted == false)
    }
}
