import Foundation
@testable import TableProOracleCore
import Testing

struct OracleServerReleaseTests {
    @Test func testIdentityColumnsArriveInTwelveC() {
        #expect(!OracleServerRelease(major: 11).hasIdentityColumns)
        #expect(OracleServerRelease(major: 12).hasIdentityColumns)
        #expect(OracleServerRelease(major: 23).hasIdentityColumns)
    }

    @Test func testDefaultOnNullForUpdateArrivesIn23ai() {
        #expect(!OracleServerRelease(major: 12).hasDefaultOnNullForUpdate)
        #expect(!OracleServerRelease(major: 21).hasDefaultOnNullForUpdate)
        #expect(OracleServerRelease(major: 23).hasDefaultOnNullForUpdate)
    }

    @Test func testTheUpdateDefaultsToZero() {
        #expect(OracleServerRelease(major: 19).update == 0)
        #expect(OracleServerRelease(major: 23, update: 26).update == 26)
    }

    /// 26ai reports itself as release 23, update 26 (`23.26.3.0.0`, measured).
    @Test func testVectorInfoArrivesIn23ai4() {
        #expect(!OracleServerRelease(major: 21).hasVectorInfo)
        #expect(!OracleServerRelease(major: 23).hasVectorInfo)
        #expect(!OracleServerRelease(major: 23, update: 3).hasVectorInfo)
        #expect(OracleServerRelease(major: 23, update: 4).hasVectorInfo)
        #expect(OracleServerRelease(major: 23, update: 26).hasVectorInfo)
        #expect(OracleServerRelease(major: 26).hasVectorInfo)
    }
}
