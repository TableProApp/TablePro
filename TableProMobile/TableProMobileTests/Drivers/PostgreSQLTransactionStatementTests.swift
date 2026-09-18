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

    @Test("Every transaction block reports the user's own transaction")
    func openTransactionBlocks() {
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_INTRANS) == .explicitTransaction)
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_INERROR) == .explicitTransaction)
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_ACTIVE) == .explicitTransaction)
    }

    @Test("A connection libpq cannot read reports an unknown state")
    func unknownStatus() {
        #expect(PostgreSQLSessionTransaction.state(from: PQTRANS_UNKNOWN) == .unknown)
    }
}
