//
//  MySQLTransactionStatementTests.swift
//  TableProTests
//

import TableProPluginKit
import Testing

@Suite("MySQL Begin Transaction Statement")
struct MySQLTransactionStatementTests {
    @Test("A read-write transaction declares the access mode so a read-only session default is overridden")
    func readWriteDeclaresAccessMode() {
        #expect(mysqlBeginTransactionStatement(mode: .readWrite) == "START TRANSACTION READ WRITE")
    }

    @Test("A server-default transaction inherits the session access mode")
    func serverDefaultInheritsSessionMode() {
        #expect(mysqlBeginTransactionStatement(mode: .serverDefault) == "START TRANSACTION")
    }
}
