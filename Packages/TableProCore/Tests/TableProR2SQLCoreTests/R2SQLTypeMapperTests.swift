import XCTest
@testable import TableProR2SQLCore

final class R2SQLTypeMapperTests: XCTestCase {
    func testArrowTextTypesNormalizeToString() {
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: "Utf8"), "STRING")
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: "LargeUtf8"), "STRING")
    }

    func testArrowListTypesNormalizeToArray() {
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: "List(Int64)"), "ARRAY")
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: "LargeList(Utf8)"), "ARRAY")
    }

    func testStructAndMapNormalize() {
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: "Struct(a Int64)"), "STRUCT")
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: "Map(Utf8, Int64)"), "MAP")
    }

    func testTypesTablePromAlreadyUnderstandsArePassedThrough() {
        for name in ["Int64", "Float64", "Boolean", "Date32", "Decimal128(10, 2)", "Timestamp(Microsecond, None)"] {
            XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: name), name)
        }
    }

    func testNormalizationIsCaseInsensitive() {
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: "utf8"), "STRING")
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: "STRUCT"), "STRUCT")
    }

    func testEmptyTypeStaysEmpty() {
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(rawTypeName: ""), "")
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(for: R2SQLField(name: "a", rawType: nil)), "")
    }

    func testCategoryClassifiesStructuredBinaryAndScalar() {
        XCTAssertEqual(R2SQLTypeMapper.category(rawTypeName: "Struct(a Int64)"), .structured)
        XCTAssertEqual(R2SQLTypeMapper.category(rawTypeName: "List(Int64)"), .structured)
        XCTAssertEqual(R2SQLTypeMapper.category(rawTypeName: "Map(Utf8, Int64)"), .structured)
        XCTAssertEqual(R2SQLTypeMapper.category(rawTypeName: "Binary"), .binary)
        XCTAssertEqual(R2SQLTypeMapper.category(rawTypeName: "Int64"), .scalar)
    }

    func testBinaryValueDecodesFromBase64() {
        let value = R2SQLTypeMapper.value(for: .string("AQID"), rawTypeName: "Binary")
        XCTAssertEqual(value, .bytes([1, 2, 3]))
    }

    func testBinaryValueFallsBackToTextWhenNotBase64() {
        let value = R2SQLTypeMapper.value(for: .string("not base64!"), rawTypeName: "Binary")
        XCTAssertEqual(value, .text("not base64!"))
    }

    func testNilAndNullBecomeNullValue() {
        XCTAssertEqual(R2SQLTypeMapper.value(for: nil, rawTypeName: "Int64"), .null)
        XCTAssertEqual(R2SQLTypeMapper.value(for: .null, rawTypeName: "Int64"), .null)
    }

    func testFieldTypeNameReadsObjectShapedType() {
        let field = R2SQLField(name: "a", rawType: .object(["name": .string("struct")]))
        XCTAssertEqual(field.typeName, "struct")
        XCTAssertEqual(R2SQLTypeMapper.displayTypeName(for: field), "STRUCT")
    }

    func testFieldDecodesFlatStringType() throws {
        let json = #"{"name":"id","type":"Int64"}"#
        let field = try JSONDecoder().decode(R2SQLField.self, from: Data(json.utf8))
        XCTAssertEqual(field.name, "id")
        XCTAssertEqual(field.typeName, "Int64")
    }

    func testFieldDecodesObjectShapedTypeWithoutFailing() throws {
        let json = #"{"name":"s","type":{"name":"struct","fields":[]}}"#
        let field = try JSONDecoder().decode(R2SQLField.self, from: Data(json.utf8))
        XCTAssertEqual(field.name, "s")
        XCTAssertEqual(field.typeName, "struct")
    }
}
