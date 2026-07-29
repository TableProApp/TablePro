import XCTest
@testable import TableProTrinoCore

final class TrinoDDLSQLTests: XCTestCase {
    private let target = "\"hive\".\"sales\".\"orders\""

    func testColumnDefinitionWithComment() {
        let spec = TrinoColumnSpec(name: "amount", type: "decimal(10,2)", nullable: false, comment: "the total")
        XCTAssertEqual(
            TrinoDDLSQL.columnDefinition(spec),
            "\"amount\" decimal(10,2) NOT NULL COMMENT 'the total'"
        )
    }

    func testCreateTable() {
        let columns = [
            TrinoColumnSpec(name: "id", type: "bigint", nullable: false, comment: nil),
            TrinoColumnSpec(name: "name", type: "varchar(50)", nullable: true, comment: nil),
        ]
        let sql = TrinoDDLSQL.createTable(qualifiedTable: target, columns: columns, tableComment: "orders", ifNotExists: true)
        XCTAssertEqual(
            sql,
            "CREATE TABLE IF NOT EXISTS \(target) (\n  \"id\" bigint NOT NULL,\n  \"name\" varchar(50)\n) COMMENT 'orders'"
        )
    }

    func testCreateTableEmptyColumnsReturnsNil() {
        XCTAssertNil(TrinoDDLSQL.createTable(qualifiedTable: target, columns: [], tableComment: nil, ifNotExists: false))
    }

    func testAddDropRenameRetype() {
        XCTAssertEqual(
            TrinoDDLSQL.addColumn(qualifiedTable: target, column: TrinoColumnSpec(name: "c", type: "varchar", nullable: true, comment: nil)),
            "ALTER TABLE \(target) ADD COLUMN \"c\" varchar"
        )
        XCTAssertEqual(TrinoDDLSQL.dropColumn(qualifiedTable: target, name: "c"), "ALTER TABLE \(target) DROP COLUMN \"c\"")
        XCTAssertEqual(
            TrinoDDLSQL.renameColumn(qualifiedTable: target, from: "a", to: "b"),
            "ALTER TABLE \(target) RENAME COLUMN \"a\" TO \"b\""
        )
        XCTAssertEqual(
            TrinoDDLSQL.setColumnType(qualifiedTable: target, name: "a", type: "bigint"),
            "ALTER TABLE \(target) ALTER COLUMN \"a\" SET DATA TYPE bigint"
        )
    }

    func testComments() {
        XCTAssertEqual(
            TrinoDDLSQL.setColumnComment(qualifiedTable: target, name: "a", comment: "note"),
            "COMMENT ON COLUMN \(target).\"a\" IS 'note'"
        )
        XCTAssertEqual(
            TrinoDDLSQL.setColumnComment(qualifiedTable: target, name: "a", comment: nil),
            "COMMENT ON COLUMN \(target).\"a\" IS NULL"
        )
        XCTAssertEqual(
            TrinoDDLSQL.setTableComment(qualifiedTable: target, comment: "hi"),
            "COMMENT ON TABLE \(target) IS 'hi'"
        )
    }
}

final class TrinoRowEditSQLTests: XCTestCase {
    private let target = "\"hive\".\"sales\".\"orders\""

    func testInsert() {
        let columns = [
            TrinoColumnValue(name: "id", value: .text("7"), typeName: "bigint"),
            TrinoColumnValue(name: "name", value: .text("Ann"), typeName: "varchar(20)"),
        ]
        XCTAssertEqual(
            TrinoRowEditSQL.insert(qualifiedTable: target, columns: columns),
            "INSERT INTO \(target) (\"id\", \"name\") VALUES (7, 'Ann')"
        )
    }

    func testUpdateWithKey() {
        let sql = TrinoRowEditSQL.update(
            qualifiedTable: target,
            assignments: [TrinoColumnValue(name: "name", value: .text("Bob"), typeName: "varchar(20)")],
            keyColumns: [TrinoColumnValue(name: "id", value: .text("7"), typeName: "bigint")]
        )
        XCTAssertEqual(sql, "UPDATE \(target) SET \"name\" = 'Bob' WHERE \"id\" = 7")
    }

    func testDeleteWithNullKey() {
        let sql = TrinoRowEditSQL.delete(
            qualifiedTable: target,
            keyColumns: [TrinoColumnValue(name: "id", value: .null, typeName: "bigint")]
        )
        XCTAssertEqual(sql, "DELETE FROM \(target) WHERE \"id\" IS NULL")
    }

    func testPredicateSkipsStructuredColumns() {
        let sql = TrinoRowEditSQL.delete(
            qualifiedTable: target,
            keyColumns: [
                TrinoColumnValue(name: "tags", value: .text("[1]"), typeName: "array(integer)"),
                TrinoColumnValue(name: "id", value: .text("7"), typeName: "bigint"),
            ]
        )
        XCTAssertEqual(sql, "DELETE FROM \(target) WHERE \"id\" = 7")
    }

    func testDeleteWithOnlyStructuredColumnsReturnsNil() {
        XCTAssertNil(TrinoRowEditSQL.delete(
            qualifiedTable: target,
            keyColumns: [TrinoColumnValue(name: "tags", value: .text("[1]"), typeName: "array(integer)")]
        ))
    }

    func testUpdateWithoutKeyReturnsNil() {
        XCTAssertNil(TrinoRowEditSQL.update(
            qualifiedTable: target,
            assignments: [TrinoColumnValue(name: "name", value: .text("Bob"), typeName: "varchar(20)")],
            keyColumns: []
        ))
    }
}
