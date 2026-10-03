@testable import TableProOracleCore
import XCTest

final class OracleQueryTimeoutTests: XCTestCase {
    func testTimeoutBoundsCannotOverflowNativeUnits() {
        let maximum = OracleQueryTimeout.maximumSeconds

        XCTAssertEqual(OracleQueryTimeout.boundedSeconds(maximum), maximum)
        XCTAssertEqual(OracleQueryTimeout.boundedSeconds(maximum + 1), maximum)
        XCTAssertEqual(OracleQueryTimeout.boundedSeconds(Int.max), maximum)
        XCTAssertEqual(OracleQueryTimeout.boundedSeconds(-1), 0)
        XCTAssertEqual(OracleQueryTimeout.nanoseconds(Double(maximum)), UInt64(maximum) * 1_000_000_000)
        XCTAssertEqual(OracleQueryTimeout.nanoseconds(.infinity), UInt64(maximum) * 1_000_000_000)
        XCTAssertEqual(OracleQueryTimeout.nanoseconds(.nan), 0)
    }
}
