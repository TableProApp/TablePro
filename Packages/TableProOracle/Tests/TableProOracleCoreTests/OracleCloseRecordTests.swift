import Foundation
@testable import TableProOracleCore
import Testing

/// Two closers reach one channel: whoever decided to close it, and the statement that was on the
/// wire when it went. The second arrives as `clientClosedConnection` and knows nothing about the
/// first, so it must not be able to talk the connection into redialing after the app let it go.
struct OracleCloseRecordTests {
    @Test func testAFreshRecordPermitsBothRecoveries() {
        var record = OracleCloseRecord()
        #expect(record.allowsReconnect)
        #expect(!record.allowsSessionSetupReplay)

        record.record(.pingTimedOut)
        #expect(record.allowsReconnect)
        #expect(record.allowsSessionSetupReplay)
    }

    @Test func testTheDyingStatementCannotOverwriteADeliberateTeardown() {
        var record = OracleCloseRecord()
        record.record(.userRequested)
        record.record(.channelAlreadyClosed)

        #expect(record.reason == .userRequested)
        #expect(!record.allowsSessionSetupReplay)
        #expect(!record.allowsReconnect)
    }

    @Test func testATeardownArrivingSecondStillFinishesTheConnection() {
        var record = OracleCloseRecord()
        record.record(.transportError)
        record.record(.userRequested)

        #expect(record.reason == .transportError)
        #expect(!record.allowsSessionSetupReplay)
        #expect(!record.allowsReconnect)
    }

    @Test func testADyingProbeCannotOverwriteAConnectDeadlineTeardown() {
        var record = OracleCloseRecord()
        record.record(.connectTimedOut)
        record.record(.channelAlreadyClosed)

        #expect(record.reason == .connectTimedOut)
        #expect(!record.allowsSessionSetupReplay)
        #expect(!record.allowsReconnect)
    }

    @Test func testCancellingAQueryDoesNotFinishTheConnection() {
        var record = OracleCloseRecord()
        record.record(.queryCancelled)

        #expect(record.allowsReconnect)
        #expect(!record.allowsSessionSetupReplay)
    }

    /// A connect clears the reason so the next failure reads its own, and leaves `isFinished`
    /// alone: the plugin never reuses a connection the app disconnected.
    @Test func testConnectingClearsTheReasonButNotTheTeardown() {
        var record = OracleCloseRecord()
        record.record(.transportError)
        record.clearOnConnect()
        #expect(record.reason == nil)
        #expect(record.allowsReconnect)
        #expect(!record.allowsSessionSetupReplay)

        record.record(.userRequested)
        record.clearOnConnect()
        #expect(!record.allowsReconnect)
    }
}
