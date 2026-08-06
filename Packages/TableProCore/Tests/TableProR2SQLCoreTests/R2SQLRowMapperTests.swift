import XCTest
@testable import TableProR2SQLCore

final class R2SQLRowMapperTests: XCTestCase {
    func testColumnOrderComesFromSchemaNotRowKeyOrder() {
        let result = R2SQLResult(
            schema: [
                R2SQLField(name: "zebra", type: "Utf8"),
                R2SQLField(name: "alpha", type: "Int64")
            ],
            rows: [["alpha": .int(1), "zebra": .string("z")]]
        )
        let mapped = R2SQLRowMapper.map(result)
        XCTAssertEqual(mapped.columns, ["zebra", "alpha"])
        XCTAssertEqual(mapped.rows.first, [.text("z"), .text("1")])
    }

    func testMissingKeyBecomesNullRatherThanFailing() {
        let result = R2SQLResult(
            schema: [R2SQLField(name: "a", type: "Int64"), R2SQLField(name: "b", type: "Utf8")],
            rows: [["a": .int(1)]]
        )
        let mapped = R2SQLRowMapper.map(result)
        XCTAssertEqual(mapped.rows.first, [.text("1"), .null])
    }

    func testExplicitJSONNullBecomesNull() {
        let result = R2SQLResult(
            schema: [R2SQLField(name: "a", type: "Int64")],
            rows: [["a": .null]]
        )
        XCTAssertEqual(R2SQLRowMapper.map(result).rows.first, [.null])
    }

    func testStructColumnSerializesAsJSONText() {
        let result = R2SQLResult(
            schema: [R2SQLField(name: "s", type: "Struct(a Int64)")],
            rows: [["s": .object(["a": .int(1)])]]
        )
        let mapped = R2SQLRowMapper.map(result)
        XCTAssertEqual(mapped.columnTypeNames, ["STRUCT"])
        XCTAssertEqual(mapped.rows.first, [.text("{\"a\":1}")])
    }

    func testListColumnSerializesAsJSONArray() {
        let result = R2SQLResult(
            schema: [R2SQLField(name: "l", type: "List(Int64)")],
            rows: [["l": .array([.int(1), .int(2)])]]
        )
        let mapped = R2SQLRowMapper.map(result)
        XCTAssertEqual(mapped.columnTypeNames, ["ARRAY"])
        XCTAssertEqual(mapped.rows.first, [.text("[1,2]")])
    }

    func testEmptySchemaProducesEmptyResultSet() {
        let mapped = R2SQLRowMapper.map(R2SQLResult(schema: [], rows: []))
        XCTAssertEqual(mapped, .empty)
    }

    func testFirstColumnStringsExtractsNames() {
        let result = R2SQLResult(
            schema: [R2SQLField(name: "namespace", type: "Utf8")],
            rows: [["namespace": .string("analytics")], ["namespace": .string("logs")]]
        )
        XCTAssertEqual(R2SQLRowMapper.firstColumnStrings(result), ["analytics", "logs"])
    }

    func testFirstColumnStringsSkipsBlanksAndNulls() {
        let result = R2SQLResult(
            schema: [R2SQLField(name: "n", type: "Utf8")],
            rows: [["n": .string("a")], ["n": .null], ["n": .string("  ")]]
        )
        XCTAssertEqual(R2SQLRowMapper.firstColumnStrings(result), ["a"])
    }
}
