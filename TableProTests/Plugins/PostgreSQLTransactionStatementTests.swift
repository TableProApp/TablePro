//
//  PostgreSQLTransactionStatementTests.swift
//  TableProTests
//

import TableProPluginKit
import Testing

@Suite("PostgreSQL Begin Transaction Statement")
struct PostgreSQLTransactionStatementTests {
    @Test("A read-write transaction declares the access mode so a read-only session default is overridden")
    func readWriteDeclaresAccessMode() {
        #expect(postgresBeginTransactionStatement(mode: .readWrite) == "BEGIN READ WRITE")
    }

    @Test("A server-default transaction inherits the session access mode")
    func serverDefaultInheritsSessionMode() {
        #expect(postgresBeginTransactionStatement(mode: .serverDefault) == "BEGIN")
    }
}
