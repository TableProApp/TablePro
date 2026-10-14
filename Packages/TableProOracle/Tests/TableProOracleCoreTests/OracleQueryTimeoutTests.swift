import Foundation
@testable import TableProOracleCore
import Testing

struct OracleQueryTimeoutTests {
    @Test func testTimeoutBoundsCannotOverflowNativeUnits() {
        let maximum = OracleQueryTimeout.maximumSeconds

        #expect(OracleQueryTimeout.boundedSeconds(maximum) == maximum)
        #expect(OracleQueryTimeout.boundedSeconds(maximum + 1) == maximum)
        #expect(OracleQueryTimeout.boundedSeconds(Int.max) == maximum)
        #expect(OracleQueryTimeout.boundedSeconds(-1) == 0)
        #expect(OracleQueryTimeout.nanoseconds(Double(maximum)) == UInt64(maximum) * 1_000_000_000)
        #expect(OracleQueryTimeout.nanoseconds(.infinity) == UInt64(maximum) * 1_000_000_000)
        #expect(OracleQueryTimeout.nanoseconds(.nan) == 0)
    }
}
