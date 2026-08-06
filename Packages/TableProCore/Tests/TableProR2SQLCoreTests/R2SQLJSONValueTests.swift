import XCTest
@testable import TableProR2SQLCore

final class R2SQLJSONValueTests: XCTestCase {
    private func decode(_ json: String) throws -> R2SQLJSONValue {
        try JSONDecoder().decode(R2SQLJSONValue.self, from: Data(json.utf8))
    }

    func testLargeInt64KeepsExactPrecision() throws {
        let value = try decode("9223372036854775807")
        XCTAssertEqual(value, .int(Int64.max))
        XCTAssertEqual(value.scalarText, "9223372036854775807")
    }

    func testIntegerBeyondInt64MaxDecodesAsUnsigned() throws {
        let value = try decode("9223372036854775808")
        XCTAssertEqual(value, .uint(9_223_372_036_854_775_808))
        XCTAssertEqual(value.scalarText, "9223372036854775808")
    }

    func testIntegerAboveTwoToTheFiftyThreeIsNotRoundedByDouble() throws {
        let value = try decode("9007199254740993")
        XCTAssertEqual(value.scalarText, "9007199254740993")
    }

    func testNegativeIntegerDecodes() throws {
        XCTAssertEqual(try decode("-42"), .int(-42))
    }

    func testFractionalNumberDecodesAsDouble() throws {
        XCTAssertEqual(try decode("1.5"), .double(1.5))
    }

    func testBooleansDecodeAsBool() throws {
        XCTAssertEqual(try decode("true"), .bool(true))
        XCTAssertEqual(try decode("false"), .bool(false))
    }

    func testNullDecodesAsNull() throws {
        XCTAssertTrue(try decode("null").isNull)
        XCTAssertNil(try decode("null").scalarText)
    }

    func testNestedNullInsideObjectIsPreserved() throws {
        let value = try decode(#"{"count":null}"#)
        XCTAssertEqual(value.jsonText(), #"{"count":null}"#)
    }

    func testNestedArrayOfStructsSerializesStably() throws {
        let value = try decode(#"[{"b":2,"a":1},{"a":3,"b":4}]"#)
        XCTAssertEqual(value.jsonText(), #"[{"a":1,"b":2},{"a":3,"b":4}]"#)
    }

    func testStringWithQuotesIsEscapedInJSONText() throws {
        let value = try decode(#""he said \"hi\"""#)
        XCTAssertEqual(value.scalarText, #"he said "hi""#)
        XCTAssertEqual(value.jsonText(), #""he said \"hi\"""#)
    }
}
