import XCTest
@testable import TableProTrinoCore

final class TrinoValueDecoderTests: XCTestCase {
    func testScalarIntBecomesText() {
        let value = TrinoValueDecoder.decode(.int(42), category: .scalar)
        XCTAssertEqual(value, .text("42"))
    }

    func testScalarBoolBecomesText() {
        XCTAssertEqual(TrinoValueDecoder.decode(.bool(true), category: .scalar), .text("true"))
        XCTAssertEqual(TrinoValueDecoder.decode(.bool(false), category: .scalar), .text("false"))
    }

    func testNullStaysNull() {
        XCTAssertEqual(TrinoValueDecoder.decode(.null, category: .scalar), .null)
        XCTAssertEqual(TrinoValueDecoder.decode(.null, category: .binary), .null)
        XCTAssertEqual(TrinoValueDecoder.decode(.null, category: .structured), .null)
    }

    func testVarbinaryBase64DecodesToBytes() {
        let value = TrinoValueDecoder.decode(.string("aGVsbG8="), category: .binary)
        XCTAssertEqual(value, .bytes([104, 101, 108, 108, 111]))
    }

    func testInvalidBase64FallsBackToText() {
        let value = TrinoValueDecoder.decode(.string("not base64!!!"), category: .binary)
        XCTAssertEqual(value, .text("not base64!!!"))
    }

    func testStructuredArrayBecomesJsonText() {
        let value = TrinoValueDecoder.decode(.array([.int(1), .string("x")]), category: .structured)
        XCTAssertEqual(value, .text("[1,\"x\"]"))
    }

    func testStructuredObjectBecomesJsonText() {
        let value = TrinoValueDecoder.decode(.object(["a": .int(1)]), category: .structured)
        XCTAssertEqual(value, .text("{\"a\":1}"))
    }
}
