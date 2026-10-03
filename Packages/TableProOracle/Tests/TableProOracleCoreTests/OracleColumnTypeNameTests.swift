import OracleNIO
@testable import TableProOracleCore
import XCTest

final class OracleColumnTypeNameTests: XCTestCase {
    /// An SDO_GEOMETRY or any other object column used to be labelled "unknown" in the grid header
    /// and in its cell placeholder.
    func testObjectColumnIsNamed() {
        XCTAssertEqual(OracleCoreConnection.oracleTypeName(.object), "object")
        XCTAssertEqual(OracleCellFormatting.unsupportedPlaceholder(typeName: "object"), "<unsupported: object>")
    }

    func testCursorColumnIsNamed() {
        XCTAssertEqual(OracleCoreConnection.oracleTypeName(.cursor), "cursor")
    }

    func testNCLOBFetchedAsLongIsNamed() {
        XCTAssertEqual(OracleCoreConnection.oracleTypeName(.longNVarchar), "nclob")
    }
}
