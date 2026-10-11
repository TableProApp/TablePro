import OracleNIO
@testable import TableProOracleCore
import XCTest

final class OracleColumnTypeNameTests: XCTestCase {
    /// An SDO_GEOMETRY or any other object column used to be labelled "unknown" in the grid header
    /// and in its cell placeholder.
    func testObjectColumnIsNamed() {
        XCTAssertEqual(OracleCellDecoding.typeName(of: .object), "object")
        XCTAssertEqual(OracleCellFormatting.unsupportedPlaceholder(typeName: "object"), "<unsupported: object>")
    }

    func testCursorColumnIsNamed() {
        XCTAssertEqual(OracleCellDecoding.typeName(of: .cursor), "cursor")
    }

    func testNCLOBFetchedAsLongIsNamed() {
        XCTAssertEqual(OracleCellDecoding.typeName(of: .longNVarchar), "nclob")
    }

    /// The header names a LOB by its declared type; the driver fetches it as LONG, which named a CLOB
    /// `long` and a BLOB `long raw`.
    func testLOBsAreNamedByTheirDeclaredType() {
        XCTAssertEqual(OracleCellDecoding.typeName(of: .clob), "clob")
        XCTAssertEqual(OracleCellDecoding.typeName(of: .blob), "blob")
        XCTAssertEqual(OracleCellDecoding.typeName(of: .nCLOB), "nclob")
    }

    func testEveryTypeTheDriverDescribesHasAName() {
        let described: [OracleDataType] = [
            .bFile, .binaryDouble, .binaryFloat, .binaryInteger, .blob, .boolean, .char, .clob, .cursor, .date,
            .intervalDS, .intervalYM, .json, .long, .longNVarchar, .longRAW, .nChar, .nCLOB, .number, .nVarchar,
            .object, .raw, .ref, .rowID, .timestamp, .timestampLTZ, .timestampTZ, .uRowID, .varchar, .vector,
        ]
        for type in described {
            XCTAssertNotEqual(OracleCellDecoding.typeName(of: type), "unknown", "\(type)")
        }
        XCTAssertEqual(OracleCellDecoding.typeName(of: .uRowID), "urowid")
        XCTAssertEqual(OracleCellDecoding.typeName(of: .ref), "ref")
    }

    /// A datetime column's scale is its fractional-second digits; the describe reports -127 for a column
    /// that has no scale, which is not a datetime scale.
    func testFractionDigitsComeFromTheScale() {
        XCTAssertEqual(OracleResultColumn(name: "TS", dataType: .timestamp, scale: 6).fractionDigits, 6)
        XCTAssertEqual(OracleResultColumn(name: "TS", dataType: .timestamp, scale: 0).fractionDigits, 0)
        XCTAssertEqual(OracleResultColumn(name: "N", dataType: .number, scale: -127).fractionDigits, 9)
    }

    func testDescriptorUsesTheDeclaredTypeName() {
        let column = OracleResultColumn(name: "NOTE", dataType: .clob, scale: 0)
        XCTAssertEqual(column.descriptor, OracleColumnDescriptor(name: "NOTE", typeName: "clob"))
    }
}
