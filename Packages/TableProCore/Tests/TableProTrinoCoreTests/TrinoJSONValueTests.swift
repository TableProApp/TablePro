import XCTest
@testable import TableProTrinoCore

final class TrinoJSONValueTests: XCTestCase {
    private func decode(_ json: String) throws -> TrinoJSONValue {
        try JSONDecoder().decode(TrinoJSONValue.self, from: Data(json.utf8))
    }

    func testDecodesNull() throws {
        XCTAssertEqual(try decode("null"), .null)
    }

    func testDecodesBool() throws {
        XCTAssertEqual(try decode("true"), .bool(true))
        XCTAssertEqual(try decode("false"), .bool(false))
    }

    func testBigintKeepsFullPrecision() throws {
        let value = try decode("9007199254740993")
        XCTAssertEqual(value, .int(9_007_199_254_740_993))
        XCTAssertEqual(value.scalarText, "9007199254740993")
    }

    func testInt64MaxRoundTrips() throws {
        let value = try decode("9223372036854775807")
        XCTAssertEqual(value, .int(9_223_372_036_854_775_807))
        XCTAssertEqual(value.scalarText, "9223372036854775807")
    }

    func testDecimalStaysString() throws {
        let value = try decode("\"12345678901234567890.99\"")
        XCTAssertEqual(value, .string("12345678901234567890.99"))
        XCTAssertEqual(value.scalarText, "12345678901234567890.99")
    }

    func testDoubleSpecialValuesArriveAsStrings() throws {
        XCTAssertEqual(try decode("\"NaN\""), .string("NaN"))
        XCTAssertEqual(try decode("\"Infinity\""), .string("Infinity"))
        XCTAssertEqual(try decode("\"-Infinity\""), .string("-Infinity"))
    }

    func testArrayJsonText() throws {
        let value = try decode("[1,2,3]")
        XCTAssertEqual(value.jsonText(), "[1,2,3]")
    }

    func testObjectJsonTextSortsKeys() throws {
        let value = try decode("{\"b\":2,\"a\":1}")
        XCTAssertEqual(value.jsonText(), "{\"a\":1,\"b\":2}")
    }

    func testNestedArrayOfObjectsSerializes() throws {
        let value = try decode("[{\"k\":\"v\"},{\"k\":\"w\"}]")
        XCTAssertEqual(value.jsonText(), "[{\"k\":\"v\"},{\"k\":\"w\"}]")
    }
}
