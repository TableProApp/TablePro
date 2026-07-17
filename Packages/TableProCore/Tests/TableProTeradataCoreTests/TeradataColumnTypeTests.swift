import XCTest
@testable import TableProTeradataCore

final class TeradataColumnTypeTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(TeradataColumnType.displayName(
            dbcColumnType: "I ", length: 4, totalDigits: 0, fractionalDigits: 0), "INTEGER")
        XCTAssertEqual(TeradataColumnType.displayName(
            dbcColumnType: "CV", length: 50, totalDigits: 0, fractionalDigits: 0), "VARCHAR(50)")
        XCTAssertEqual(TeradataColumnType.displayName(
            dbcColumnType: "CF", length: 10, totalDigits: 0, fractionalDigits: 0), "CHAR(10)")
        XCTAssertEqual(TeradataColumnType.displayName(
            dbcColumnType: "D ", length: 8, totalDigits: 18, fractionalDigits: 2), "DECIMAL(18,2)")
        XCTAssertEqual(TeradataColumnType.displayName(
            dbcColumnType: "TS", length: 26, totalDigits: 0, fractionalDigits: 0), "TIMESTAMP")
        XCTAssertEqual(TeradataColumnType.displayName(
            dbcColumnType: "I8", length: 8, totalDigits: 0, fractionalDigits: 0), "BIGINT")
    }

    func testUnknownFallsBackToCode() {
        XCTAssertEqual(TeradataColumnType.displayName(
            dbcColumnType: "ZZ", length: 0, totalDigits: 0, fractionalDigits: 0), "ZZ")
    }

    func testWireCategories() {
        XCTAssertEqual(TeradataColumnType.category(wireTypeCode: 497), .numeric)
        XCTAssertEqual(TeradataColumnType.category(wireTypeCode: 448), .text)
        XCTAssertEqual(TeradataColumnType.category(wireTypeCode: 752), .temporal)
        XCTAssertEqual(TeradataColumnType.category(wireTypeCode: 688), .binary)
        XCTAssertEqual(TeradataColumnType.category(wireTypeCode: 400), .largeObject)
    }
}
