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
}
