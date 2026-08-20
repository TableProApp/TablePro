import XCTest
@testable import TableProTrinoCore

final class TrinoLiteralTests: XCTestCase {
    func testNull() {
        XCTAssertEqual(TrinoLiteral.render(.null, typeName: "varchar(10)"), "NULL")
    }

    func testVarcharQuotesNumericLookingText() {
        XCTAssertEqual(TrinoLiteral.render(.text("123"), typeName: "varchar(10)"), "'123'")
    }

    func testVarcharEscapesApostrophe() {
        XCTAssertEqual(TrinoLiteral.render(.text("O'Brien"), typeName: "varchar(20)"), "'O''Brien'")
    }

    func testNumericColumnEmitsBareNumber() {
        XCTAssertEqual(TrinoLiteral.render(.text("123"), typeName: "bigint"), "123")
        XCTAssertEqual(TrinoLiteral.render(.text("-4.5"), typeName: "double"), "-4.5")
        XCTAssertEqual(TrinoLiteral.render(.text("10.25"), typeName: "decimal(10,2)"), "10.25")
    }

    func testNumericColumnQuotesNonNumericText() {
        XCTAssertEqual(TrinoLiteral.render(.text("NaN"), typeName: "double"), "'NaN'")
    }

    func testBoolean() {
        XCTAssertEqual(TrinoLiteral.render(.text("true"), typeName: "boolean"), "true")
        XCTAssertEqual(TrinoLiteral.render(.text("FALSE"), typeName: "boolean"), "false")
    }

    func testTemporalLiterals() {
        XCTAssertEqual(TrinoLiteral.render(.text("2020-01-02"), typeName: "date"), "DATE '2020-01-02'")
        XCTAssertEqual(TrinoLiteral.render(.text("12:00:00"), typeName: "time(3)"), "TIME '12:00:00'")
        XCTAssertEqual(
            TrinoLiteral.render(.text("2020-01-02 03:04:05"), typeName: "timestamp(3)"),
            "TIMESTAMP '2020-01-02 03:04:05'"
        )
        XCTAssertEqual(
            TrinoLiteral.render(.text("12:00:00 +00:00"), typeName: "time(3) with time zone"),
            "TIME '12:00:00 +00:00'"
        )
    }

    func testJsonUuidIpAddress() {
        XCTAssertEqual(TrinoLiteral.render(.text("{\"a\":1}"), typeName: "json"), "JSON '{\"a\":1}'")
        XCTAssertEqual(
            TrinoLiteral.render(.text("12151fd2-7586-11e9-8f9e-2a86e4085a59"), typeName: "uuid"),
            "UUID '12151fd2-7586-11e9-8f9e-2a86e4085a59'"
        )
        XCTAssertEqual(TrinoLiteral.render(.text("10.0.0.1"), typeName: "ipaddress"), "CAST('10.0.0.1' AS ipaddress)")
    }

    func testVarbinaryFromBytes() {
        XCTAssertEqual(TrinoLiteral.render(.bytes([104, 105]), typeName: "varbinary"), "X'6869'")
    }

    func testStructuredCastsFromJson() {
        XCTAssertEqual(
            TrinoLiteral.render(.text("[1,2,3]"), typeName: "array(integer)"),
            "CAST(json_parse('[1,2,3]') AS array(integer))"
        )
    }
}
