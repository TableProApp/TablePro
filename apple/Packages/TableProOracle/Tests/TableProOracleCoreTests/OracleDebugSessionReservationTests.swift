import Foundation
@testable import TableProOracleCore
import Testing

// A debug target is a statement paused at a breakpoint for as long as a person reads it. The health check's
// staleness limit would close it after 300 seconds, and a query timeout sooner.
struct OracleDebugSessionReservationTests {
    private func connection() -> OracleCoreConnection {
        OracleCoreConnection(options: OracleConnectionOptions(host: "127.0.0.1", user: "probe", password: "probe_pw"))
    }

    @Test func testAnOrdinarySessionKeepsTheStalenessLimit() {
        let session = connection()
        #expect(session.wedgedStatementLimit == .seconds(300))
        session.applyQueryTimeout(600)
        #expect(session.wedgedStatementLimit == .seconds(600))
    }

    @Test func testADebugSessionHasNoStalenessLimitAndIgnoresQueryTimeouts() {
        let session = connection()
        session.applyQueryTimeout(600)
        session.reserveForDebugging()
        #expect(session.isReservedForDebugging)
        #expect(session.wedgedStatementLimit == nil)
        session.applyQueryTimeout(30)
        #expect(session.wedgedStatementLimit == nil)
    }

    @Test func testABusyDebugSessionIsAlwaysReportedAlive() {
        #expect(OraclePingDecision.of(.busy(for: .seconds(86_400)), wedgedAfter: nil) == .reportAlive)
        #expect(OraclePingDecision.of(.acquired, wedgedAfter: nil) == .probe)
        #expect(OraclePingDecision.of(.busy(for: .seconds(301)), wedgedAfter: .seconds(300)) == .reportWedged)
    }

    // A reserved session never redials: a new session would not be the one being debugged.
    @Test func testADebugSessionWithoutAChannelDoesNotRedial() async {
        let session = connection()
        session.reserveForDebugging()
        await #expect(throws: OracleCoreError.notConnected) {
            _ = try await session.executeDirect("ROLLBACK")
        }
    }
}
