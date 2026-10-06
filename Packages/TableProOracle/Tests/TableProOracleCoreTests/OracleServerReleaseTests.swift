@testable import TableProOracleCore
import XCTest

final class OracleServerReleaseTests: XCTestCase {
    func testIdentityColumnsArriveInTwelveC() {
        XCTAssertFalse(OracleServerRelease(major: 11).hasIdentityColumns)
        XCTAssertTrue(OracleServerRelease(major: 12).hasIdentityColumns)
        XCTAssertTrue(OracleServerRelease(major: 23).hasIdentityColumns)
    }

    func testDefaultOnNullForUpdateArrivesIn23ai() {
        XCTAssertFalse(OracleServerRelease(major: 12).hasDefaultOnNullForUpdate)
        XCTAssertFalse(OracleServerRelease(major: 21).hasDefaultOnNullForUpdate)
        XCTAssertTrue(OracleServerRelease(major: 23).hasDefaultOnNullForUpdate)
    }

    func testTheUpdateDefaultsToZero() {
        XCTAssertEqual(OracleServerRelease(major: 19).update, 0)
        XCTAssertEqual(OracleServerRelease(major: 23, update: 26).update, 26)
    }

    /// 26ai reports itself as release 23, update 26 (`23.26.3.0.0`, measured).
    func testVectorInfoArrivesIn23ai4() {
        XCTAssertFalse(OracleServerRelease(major: 21).hasVectorInfo)
        XCTAssertFalse(OracleServerRelease(major: 23).hasVectorInfo)
        XCTAssertFalse(OracleServerRelease(major: 23, update: 3).hasVectorInfo)
        XCTAssertTrue(OracleServerRelease(major: 23, update: 4).hasVectorInfo)
        XCTAssertTrue(OracleServerRelease(major: 23, update: 26).hasVectorInfo)
        XCTAssertTrue(OracleServerRelease(major: 26).hasVectorInfo)
    }
}
