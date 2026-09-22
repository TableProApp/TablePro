@testable import TableProOracleCore
import XCTest

/// Two closers reach one channel: whoever decided to close it, and the statement that was on the
/// wire when it went. The second arrives as `clientClosedConnection` and knows nothing about the
/// first, so it must not be able to talk the connection into redialing after the app let it go.
final class OracleCloseRecordTests: XCTestCase {
    func testAFreshRecordPermitsBothRecoveries() {
        var record = OracleCloseRecord()
        XCTAssertTrue(record.allowsReconnect)
        XCTAssertFalse(record.allowsSessionSetupReplay)

        record.record(.pingTimedOut)
        XCTAssertTrue(record.allowsReconnect)
        XCTAssertTrue(record.allowsSessionSetupReplay)
    }

    func testTheDyingStatementCannotOverwriteADeliberateTeardown() {
        var record = OracleCloseRecord()
        record.record(.userRequested)
        record.record(.channelAlreadyClosed)

        XCTAssertEqual(record.reason, .userRequested)
        XCTAssertFalse(record.allowsSessionSetupReplay)
        XCTAssertFalse(record.allowsReconnect)
    }

    func testATeardownArrivingSecondStillFinishesTheConnection() {
        var record = OracleCloseRecord()
        record.record(.transportError)
        record.record(.userRequested)

        XCTAssertEqual(record.reason, .transportError)
        XCTAssertFalse(record.allowsSessionSetupReplay)
        XCTAssertFalse(record.allowsReconnect)
    }

    func testCancellingAQueryDoesNotFinishTheConnection() {
        var record = OracleCloseRecord()
        record.record(.queryCancelled)

        XCTAssertTrue(record.allowsReconnect)
        XCTAssertFalse(record.allowsSessionSetupReplay)
    }

    /// A connect clears the reason so the next failure reads its own, and leaves `isFinished`
    /// alone: the plugin never reuses a connection the app disconnected.
    func testConnectingClearsTheReasonButNotTheTeardown() {
        var record = OracleCloseRecord()
        record.record(.transportError)
        record.clearOnConnect()
        XCTAssertNil(record.reason)
        XCTAssertTrue(record.allowsReconnect)
        XCTAssertFalse(record.allowsSessionSetupReplay)

        record.record(.userRequested)
        record.clearOnConnect()
        XCTAssertFalse(record.allowsReconnect)
    }
}
