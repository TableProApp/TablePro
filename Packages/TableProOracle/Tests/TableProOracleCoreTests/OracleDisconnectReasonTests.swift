@testable import TableProOracleCore
import XCTest

/// A statement may only be sent again across a close that took the channel away from a session
/// somebody still wants. Replaying across a deliberate teardown opens a socket nobody owns, and
/// reports a switch the caller has already abandoned as having succeeded.
final class OracleDisconnectReasonTests: XCTestCase {
    func testADeliberateTeardownIsNeverReplayedAcross() {
        XCTAssertFalse(OracleDisconnectReason.userRequested.allowsReplay)
        XCTAssertFalse(OracleDisconnectReason.queryCancelled.allowsReplay)
        XCTAssertFalse(OracleDisconnectReason.abandonedLoginAttempt.allowsReplay)
    }

    func testAChannelTakenFromALiveSessionMayBeReplayedAcross() {
        XCTAssertTrue(OracleDisconnectReason.pingTimedOut.allowsReplay)
        XCTAssertTrue(OracleDisconnectReason.queryTimedOut.allowsReplay)
        XCTAssertTrue(OracleDisconnectReason.wedgedStatement.allowsReplay)
        XCTAssertTrue(OracleDisconnectReason.channelAlreadyClosed.allowsReplay)
        XCTAssertTrue(OracleDisconnectReason.transportError.allowsReplay)
        XCTAssertTrue(OracleDisconnectReason.fatalProtocolError.allowsReplay)
    }

    /// Only the app's own disconnect ends the connection. Cancelling a query ends one statement,
    /// and an abandoned login attempt closes its own handle without touching the one installed.
    func testOnlyTheAppsOwnDisconnectEndsTheConnection() {
        XCTAssertTrue(OracleDisconnectReason.userRequested.endsConnection)
        for reason in [
            OracleDisconnectReason.queryCancelled, .queryTimedOut, .pingTimedOut, .wedgedStatement,
            .channelAlreadyClosed, .fatalProtocolError, .transportError, .abandonedLoginAttempt
        ] {
            XCTAssertFalse(reason.endsConnection, String(describing: reason))
        }
    }

    func testEveryReasonSaysSomethingTheLogCanUse() {
        let reasons: [OracleDisconnectReason] = [
            .userRequested, .queryCancelled, .queryTimedOut, .pingTimedOut, .wedgedStatement,
            .channelAlreadyClosed, .fatalProtocolError, .transportError, .abandonedLoginAttempt
        ]
        for reason in reasons {
            XCTAssertFalse(reason.logDescription.isEmpty, String(describing: reason))
        }
    }
}
