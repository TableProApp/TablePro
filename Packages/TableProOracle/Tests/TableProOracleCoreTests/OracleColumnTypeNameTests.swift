import Foundation
import OracleNIO
@testable import TableProOracleCore
import Testing

struct OracleColumnTypeNameTests {
    /// An SDO_GEOMETRY or any other object column used to be labelled "unknown" in the grid header
    /// and in its cell placeholder.
    @Test func testObjectColumnIsNamed() {
        #expect(OracleCellDecoding.typeName(of: .object) == "object")
        #expect(OracleCellFormatting.unsupportedPlaceholder(typeName: "object") == "<unsupported: object>")
    }

    @Test func testCursorColumnIsNamed() {
        #expect(OracleCellDecoding.typeName(of: .cursor) == "cursor")
    }

    @Test func testNCLOBFetchedAsLongIsNamed() {
        #expect(OracleCellDecoding.typeName(of: .longNVarchar) == "nclob")
    }

    /// The header names a LOB by its declared type; the driver fetches it as LONG, which named a CLOB
    /// `long` and a BLOB `long raw`.
    @Test func testLOBsAreNamedByTheirDeclaredType() {
        #expect(OracleCellDecoding.typeName(of: .clob) == "clob")
        #expect(OracleCellDecoding.typeName(of: .blob) == "blob")
        #expect(OracleCellDecoding.typeName(of: .nCLOB) == "nclob")
    }

    @Test func testEveryTypeTheDriverDescribesHasAName() {
        let described: [OracleDataType] = [
            .bFile, .binaryDouble, .binaryFloat, .binaryInteger, .blob, .boolean, .char, .clob, .cursor, .date,
            .intervalDS, .intervalYM, .json, .long, .longNVarchar, .longRAW, .nChar, .nCLOB, .number, .nVarchar,
            .object, .raw, .ref, .rowID, .timestamp, .timestampLTZ, .timestampTZ, .uRowID, .varchar, .vector,
        ]
        for type in described {
            #expect(OracleCellDecoding.typeName(of: type) != "unknown", "\(type)")
        }
        #expect(OracleCellDecoding.typeName(of: .uRowID) == "urowid")
        #expect(OracleCellDecoding.typeName(of: .ref) == "ref")
    }

    /// A datetime column's scale is its fractional-second digits; the describe reports -127 for a column
    /// that has no scale, which is not a datetime scale.
    @Test func testFractionDigitsComeFromTheScale() {
        #expect(OracleResultColumn(name: "TS", dataType: .timestamp, scale: 6).fractionDigits == 6)
        #expect(OracleResultColumn(name: "TS", dataType: .timestamp, scale: 0).fractionDigits == 0)
        #expect(OracleResultColumn(name: "N", dataType: .number, scale: -127).fractionDigits == 9)
    }

    @Test func testDescriptorUsesTheDeclaredTypeName() {
        let column = OracleResultColumn(name: "NOTE", dataType: .clob, scale: 0)
        #expect(column.descriptor == OracleColumnDescriptor(name: "NOTE", typeName: "clob"))
    }
}
