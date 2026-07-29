import XCTest
@testable import TableProTrinoCore

final class TrinoTypeMapperTests: XCTestCase {
    func testBaseTypeStripsParameters() {
        XCTAssertEqual(TrinoTypeMapper.baseType(fromDisplayType: "varchar(255)"), "varchar")
        XCTAssertEqual(TrinoTypeMapper.baseType(fromDisplayType: "decimal(10,2)"), "decimal")
        XCTAssertEqual(TrinoTypeMapper.baseType(fromDisplayType: "array(varchar)"), "array")
        XCTAssertEqual(TrinoTypeMapper.baseType(fromDisplayType: "row(x integer, y varchar)"), "row")
        XCTAssertEqual(TrinoTypeMapper.baseType(fromDisplayType: "bigint"), "bigint")
        XCTAssertEqual(TrinoTypeMapper.baseType(fromDisplayType: "timestamp(3) with time zone"), "timestamp")
    }

    func testScalarCategories() {
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "bigint"), .scalar)
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "varchar"), .scalar)
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "decimal"), .scalar)
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "uuid"), .scalar)
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "timestamp with time zone"), .scalar)
    }

    func testBinaryCategories() {
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "varbinary"), .binary)
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "hyperloglog"), .binary)
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "qdigest"), .binary)
    }

    func testStructuredCategories() {
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "array"), .structured)
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "map"), .structured)
        XCTAssertEqual(TrinoTypeMapper.category(forRawType: "row"), .structured)
    }

    func testColumnCategoryUsesTypeSignatureRawType() {
        let column = TrinoColumn(
            name: "c",
            type: "array(varchar)",
            typeSignature: TrinoTypeSignature(rawType: "array")
        )
        XCTAssertEqual(column.category, .structured)
        XCTAssertEqual(column.rawTypeName, "array")
    }

    func testColumnCategoryFallsBackToDisplayType() {
        let column = TrinoColumn(name: "c", type: "varbinary", typeSignature: nil)
        XCTAssertEqual(column.category, .binary)
    }
}
