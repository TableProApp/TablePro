import Foundation
import TableProPluginKit
import XCTest

/// Covers the two decisions that let a Dameng connection survive being stopped: which
/// statement a cancellation is allowed to reach, and which statements may be sent again on a
/// rebuilt connection.
final class DamengConnectionRecoveryTests: XCTestCase {
    func testACancellationOnlyReachesTheStatementOnTheWire() {
        var tickets = DamengStatementTickets()
        let running = tickets.issue()
        let queued = tickets.issue()

        XCTAssertTrue(tickets.beginExecuting(running))

        // Stopping the queued statement must not interrupt the one already on the socket:
        // tp_dm_cancel is connection-wide and interrupting costs the whole connection.
        XCTAssertEqual(tickets.cancel(queued), .dropQueued)
        XCTAssertEqual(tickets.cancel(running), .interruptConnection)
    }

    func testACancelledStatementNeverReachesTheSocket() {
        var tickets = DamengStatementTickets()
        let queued = tickets.issue()

        XCTAssertEqual(tickets.cancel(queued), .dropQueued)
        XCTAssertFalse(tickets.beginExecuting(queued))
    }

    func testCancellingTwiceOrLateIsIgnored() {
        var tickets = DamengStatementTickets()
        let ticket = tickets.issue()

        XCTAssertEqual(tickets.cancel(ticket), .dropQueued)
        XCTAssertEqual(tickets.cancel(ticket), .ignore)

        let finished = tickets.issue()
        XCTAssertTrue(tickets.beginExecuting(finished))
        tickets.finishExecuting(finished)
        XCTAssertEqual(tickets.cancel(finished), .ignore)

        XCTAssertEqual(tickets.cancel(9_999), .ignore)
    }

    func testATicketIsReusableAfterTheConnectionIsRebuilt() {
        var tickets = DamengStatementTickets()
        let abandoned = tickets.issue()
        XCTAssertTrue(tickets.beginExecuting(abandoned))

        tickets.reset()

        let fresh = tickets.issue()
        XCTAssertNotEqual(fresh, abandoned)
        XCTAssertTrue(tickets.beginExecuting(fresh))
        XCTAssertEqual(tickets.cancel(fresh), .interruptConnection)
    }

    func testOnlyReadsAreSentAgainOnARebuiltConnection() {
        for query in ["SELECT 1 FROM DUAL", "  show tables", "DESC APP.CUSTOMER", "EXPLAIN SELECT 1"] {
            XCTAssertEqual(DamengPluginDriver.replayPolicy(for: query), .replayable, query)
        }

        // A write may already have committed before the abandoned reply was dropped, so it is
        // reported rather than sent twice. WITH and VALUES stay out of the allowlist because
        // either can head a statement that writes.
        for query in [
            "INSERT INTO \"APP\".\"T\" VALUES(1)",
            "UPDATE \"APP\".\"T\" SET \"C\" = 1",
            "DELETE FROM \"APP\".\"T\"",
            "MERGE INTO \"APP\".\"T\" USING DUAL ON (1 = 1)",
            "CREATE TABLE \"APP\".\"T\"(\"C\" INT)",
            "BEGIN EXECUTE IMMEDIATE 'SET SCHEMA \"APP\"'; END;",
            "WITH c AS (SELECT 1) SELECT * FROM c",
            "VALUES(1)"
        ] {
            XCTAssertEqual(DamengPluginDriver.replayPolicy(for: query), .reportFailure, query)
        }
    }

    func testAReadIsStillRecognisedBehindAComment() {
        XCTAssertEqual(
            DamengPluginDriver.replayPolicy(for: "-- reload\n/* nested /* block */ */ SELECT 1 FROM DUAL"),
            .replayable
        )
    }

    /// The flag decides whether the driver reconnects, so a failure that only rejected the
    /// statement must never claim the connection is gone.
    func testAPlainFailureDoesNotClaimTheConnectionIsGone() {
        XCTAssertFalse(DamengError(message: "invalid table name").closedConnection)
        XCTAssertTrue(DamengError(message: "cancelled", closedConnection: true).closedConnection)
    }
}
