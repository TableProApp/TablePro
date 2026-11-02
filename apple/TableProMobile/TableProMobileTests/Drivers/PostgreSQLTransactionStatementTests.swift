import CLibPQ
import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProPluginKit
import Testing

@Suite("PostgreSQL transaction access mode on iOS")
struct PostgreSQLTransactionStatementTests {
    @Test("A read-write transaction opens with the access mode in the statement")
    func readWriteBegin() {
        #expect(postgresBeginTransactionStatement(mode: .readWrite) == "BEGIN READ WRITE")
    }

    @Test("The server default mode opens a plain BEGIN")
    func serverDefaultBegin() {
        #expect(postgresBeginTransactionStatement(mode: .serverDefault) == "BEGIN")
    }
}

@Suite("PostgreSQL session transaction state")
struct PostgreSQLSessionTransactionTests {
    @Test("An idle connection reports an idle session")
    func idleConnection() {
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_IDLE) == .idle)
    }

    @Test("An open transaction block reports the user's own transaction")
    func openTransactionBlock() {
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_INTRANS) == .explicitTransaction)
    }

    @Test("A block a failed statement aborted reports a transaction that can no longer commit")
    func abortedTransactionBlock() {
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_INERROR) == .abortedTransaction)
    }

    // A catalog read's SET LOCAL search_path would outlast the read inside a block, so it takes a savepoint there.
    @Test("Only an open or aborted block scopes a catalog read with a savepoint")
    func catalogReadScopesInsideABlockOnly() {
        #expect(PostgreSQLSessionTransaction.isInsideBlock(PQTRANS_INTRANS))
        #expect(PostgreSQLSessionTransaction.isInsideBlock(PQTRANS_INERROR))
        #expect(!PostgreSQLSessionTransaction.isInsideBlock(PQTRANS_IDLE))
        #expect(!PostgreSQLSessionTransaction.isInsideBlock(PQTRANS_ACTIVE))
    }

    @Test("A statement in flight reports the transaction it was sent in")
    func statementInFlightReportsStatusAtSend() {
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_ACTIVE, statusAtSend: PQTRANS_IDLE) == .idle)
        #expect(
            PostgreSQLSessionTransaction.state(from: PQTRANS_ACTIVE, statusAtSend: PQTRANS_INTRANS)
                == .explicitTransaction
        )
        #expect(
            PostgreSQLSessionTransaction.state(from: PQTRANS_ACTIVE, statusAtSend: PQTRANS_INERROR)
                == .abortedTransaction
        )
    }

    @Test("A statement in flight with no status recorded at send reports an unknown state")
    func statementInFlightWithoutStatusAtSend() {
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_ACTIVE) == .unknown)
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_ACTIVE, statusAtSend: PQTRANS_ACTIVE) == .unknown)
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_ACTIVE, statusAtSend: PQTRANS_UNKNOWN) == .unknown)
    }

    @Test("A connection libpq cannot read reports an unknown state")
    func unknownStatus() {
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_UNKNOWN) == .unknown)
    }

    @Test("Ping sends a statement only on an idle session")
    func pingSendsStatementOnlyWhenIdle() {
        #expect(PostgreSQLSessionTransaction.pingSendsStatement(in: PQTRANS_IDLE))
        for status in [PQTRANS_INTRANS, PQTRANS_INERROR, PQTRANS_ACTIVE, PQTRANS_UNKNOWN] {
            #expect(!PostgreSQLSessionTransaction.pingSendsStatement(in: status))
        }
    }

    @Test("A COMMIT the server answered with ROLLBACK in an aborted block says nothing was kept")
    func commitInAbortedBlockSaysItRolledBack() {
        #expect(
            PostgreSQLSessionTransaction.statusMessage(
                statusAtSend: PQTRANS_INERROR, commandTag: "ROLLBACK", statusAfter: PQTRANS_IDLE
            ) == "The failed transaction was rolled back. None of its changes were kept."
        )
    }

    @Test("A rollback to a savepoint, of a live transaction, or any other command adds no message")
    func otherCommandsAddNoMessage() {
        #expect(
            PostgreSQLSessionTransaction.statusMessage(
                statusAtSend: PQTRANS_INERROR, commandTag: "ROLLBACK", statusAfter: PQTRANS_INTRANS
            ) == nil
        )
        #expect(
            PostgreSQLSessionTransaction.statusMessage(
                statusAtSend: PQTRANS_INTRANS, commandTag: "ROLLBACK", statusAfter: PQTRANS_IDLE
            ) == nil
        )
        #expect(
            PostgreSQLSessionTransaction.statusMessage(
                statusAtSend: PQTRANS_INTRANS, commandTag: "COMMIT", statusAfter: PQTRANS_IDLE
            ) == nil
        )
        #expect(
            PostgreSQLSessionTransaction.statusMessage(
                statusAtSend: PQTRANS_IDLE, commandTag: "INSERT 0 1", statusAfter: PQTRANS_IDLE
            ) == nil
        )
    }
}
