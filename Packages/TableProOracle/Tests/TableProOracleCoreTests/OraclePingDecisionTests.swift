import Foundation
@testable import TableProOracleCore
import Testing

/// #3053. A health check used to wrap the whole of `executeQuery` in a ten second deadline, and
/// `executeQuery` opens by waiting on the query gate, so the deadline covered the queue rather
/// than the round trip. A probe that never got a turn closed the channel anyway, and OracleNIO
/// reports that to the statement that was running as `clientClosedConnection`.
struct OraclePingDecisionTests {
    @Test func testAProbeThatOwnsTheChannelMayRun() {
        #expect(OraclePingDecision.of(.acquired, wedgedAfter: .seconds(300)) == .probe)
    }

    @Test func testABusyChannelIsReportedAliveRatherThanClosed() {
        #expect(OraclePingDecision.of(.busy(for: .seconds(11)), wedgedAfter: .seconds(300)) == .reportAlive)
        #expect(OraclePingDecision.of(.busy(for: .seconds(299)), wedgedAfter: .seconds(300)) == .reportAlive)
    }

    @Test func testAChannelHeldPastTheStalenessLimitIsReportedWedged() {
        #expect(OraclePingDecision.of(.busy(for: .seconds(301)), wedgedAfter: .seconds(300)) == .reportWedged)
    }

    /// The limit is the app's own `max(queryTimeout, 300)` rule, so a long query timeout moves it
    /// and the escape valve still fires past it.
    @Test func testTheStalenessLimitFollowsTheQueryTimeout() {
        #expect(OraclePingDecision.of(.busy(for: .seconds(400)), wedgedAfter: .seconds(600)) == .reportAlive)
        #expect(OraclePingDecision.of(.busy(for: .seconds(601)), wedgedAfter: .seconds(600)) == .reportWedged)
    }
}
