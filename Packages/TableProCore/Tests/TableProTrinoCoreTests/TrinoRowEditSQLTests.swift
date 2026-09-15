@testable import TableProTrinoCore
import XCTest

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
