//
//  MySQLQueryTimeoutTests.swift
//  TableProTests
//

import Testing

@Suite("MySQL Query Timeout Statement")
struct MySQLQueryTimeoutTests {
    @Test("Zero disables the statement timeout on MariaDB")
    func zeroDisablesMariaDBTimeout() {
        let statement = mysqlQueryTimeoutStatement(seconds: 0, isMariaDB: true)
        #expect(statement == "SET SESSION max_statement_time = 0")
    }

    @Test("Zero disables the execution timeout on MySQL")
    func zeroDisablesMySQLTimeout() {
        let statement = mysqlQueryTimeoutStatement(seconds: 0, isMariaDB: false)
        #expect(statement == "SET SESSION max_execution_time = 0")
    }

    @Test("MariaDB timeout is expressed in seconds")
    func mariaDBTimeoutUsesSeconds() {
        let statement = mysqlQueryTimeoutStatement(seconds: 30, isMariaDB: true)
        #expect(statement == "SET SESSION max_statement_time = 30")
    }

    @Test("MySQL timeout is expressed in milliseconds")
    func mySQLTimeoutUsesMilliseconds() {
        let statement = mysqlQueryTimeoutStatement(seconds: 30, isMariaDB: false)
        #expect(statement == "SET SESSION max_execution_time = 30000")
    }
}
