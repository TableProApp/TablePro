import Foundation
@testable import TableProOracleCore
import Testing

/// A statement may only be sent again across a close that took the channel away from a session
/// somebody still wants. Replaying across a deliberate teardown opens a socket nobody owns, and
/// reports a switch the caller has already abandoned as having succeeded.
struct OracleDisconnectReasonTests {
    @Test func testADeliberateTeardownIsNeverReplayedAcross() {
        #expect(!OracleDisconnectReason.userRequested.allowsReplay)
        #expect(!OracleDisconnectReason.queryCancelled.allowsReplay)
        #expect(!OracleDisconnectReason.abandonedLoginAttempt.allowsReplay)
        #expect(!OracleDisconnectReason.connectTimedOut.allowsReplay)
        #expect(!OracleDisconnectReason.connectCancelled.allowsReplay)
    }

    @Test func testAChannelTakenFromALiveSessionMayBeReplayedAcross() {
        #expect(OracleDisconnectReason.pingTimedOut.allowsReplay)
        #expect(OracleDisconnectReason.queryTimedOut.allowsReplay)
        #expect(OracleDisconnectReason.wedgedStatement.allowsReplay)
        #expect(OracleDisconnectReason.channelAlreadyClosed.allowsReplay)
        #expect(OracleDisconnectReason.transportError.allowsReplay)
        #expect(OracleDisconnectReason.fatalProtocolError.allowsReplay)
    }

    /// A connection attempt that never completed is also finished for good. Cancelling a query
    /// ends one statement, and an abandoned login attempt closes only its own late handle.
    @Test func testAConnectAttemptTeardownEndsTheConnection() {
        #expect(OracleDisconnectReason.userRequested.endsConnection)
        #expect(OracleDisconnectReason.connectTimedOut.endsConnection)
        #expect(OracleDisconnectReason.connectCancelled.endsConnection)
        for reason in [
            OracleDisconnectReason.queryCancelled, .queryTimedOut, .pingTimedOut, .wedgedStatement,
            .channelAlreadyClosed, .fatalProtocolError, .transportError, .abandonedLoginAttempt
        ] {
            #expect(!reason.endsConnection, "\(String(describing: reason))")
        }
    }

    @Test func testEveryReasonSaysSomethingTheLogCanUse() {
        let reasons: [OracleDisconnectReason] = [
            .userRequested, .queryCancelled, .queryTimedOut, .pingTimedOut, .wedgedStatement,
            .channelAlreadyClosed, .fatalProtocolError, .transportError, .abandonedLoginAttempt,
            .connectTimedOut, .connectCancelled
        ]
        for reason in reasons {
            #expect(!reason.logDescription.isEmpty, "\(String(describing: reason))")
        }
    }
}
