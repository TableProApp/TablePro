//
//  SQLSetAssignmentsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL SET assignments")
struct SQLSetAssignmentsTests {
    private static let mysql = SQLLexicalRules(dialect: .mysql)

    private static func assignments(_ sql: String, readsList: Bool = true) -> [SQLSetAssignment] {
        var cursor = SQLTokenCursor(sql, rules: mysql)
        #expect(cursor.next()?.word == "SET")
        return SQLSetAssignments.assignments(from: &cursor, readsList: readsList)
    }

    @Test(
        "Every spelling of the session scope reaches the same variable",
        arguments: [
            "SET sql_log_bin = 0",
            "SET SESSION sql_log_bin = 0",
            "SET LOCAL sql_log_bin = 0",
            "SET @@sql_log_bin = 0",
            "SET @@SESSION.SQL_LOG_BIN= 0",
            "SET @@local.sql_log_bin = 0",
            "SET `sql_log_bin` = 0",
            "SET sql_log_bin := 0",
            "SET @@SESSION . sql_log_bin = 0"
        ]
    )
    func sessionScopeSpellings(statement: String) {
        let read = Self.assignments(statement)
        #expect(read.count == 1)
        #expect(read.first?.name == "SQL_LOG_BIN")
        #expect(read.first?.scope != .global)
    }

    @Test("A scope keyword is recorded as written")
    func scopeKeywordsAreRecorded() {
        #expect(Self.assignments("SET GLOBAL read_only = 1").first?.scope == .global)
        #expect(Self.assignments("SET PERSIST read_only = 1").first?.scope == .persist)
        #expect(Self.assignments("SET PERSIST_ONLY read_only = 1").first?.scope == .persistOnly)
        #expect(Self.assignments("SET @@GLOBAL.gtid_purged = 'x'").first?.scope == .global)
    }

    @Test("A bare double-at variable keeps no scope of its own")
    func bareDoubleAtIsUnspecified() {
        let read = Self.assignments("SET @@transaction_isolation = 'SERIALIZABLE'")
        #expect(read.first?.scope == .unspecified)
        #expect(read.first?.spelledWithAtAt == true)
        #expect(Self.assignments("SET @@SESSION.transaction_isolation = 'X'").first?.spelledWithAtAt == true)
        #expect(Self.assignments("SET transaction_isolation = 'X'").first?.spelledWithAtAt == false)
    }

    @Test("An element that is not an assignment yields nothing and does not stop the list")
    func nonAssignmentElementsAreSkipped() {
        let read = Self.assignments("SET NAMES utf8mb4, sql_log_bin = 0")
        #expect(read.map(\.name) == ["SQL_LOG_BIN"])
        #expect(Self.assignments("SET CHARACTER SET utf8mb4").isEmpty)
    }

    @Test("A user variable is not a system variable")
    func userVariablesYieldNothing() {
        #expect(Self.assignments("SET @MYSQLDUMP_TEMP_LOG_BIN = @@SESSION.SQL_LOG_BIN").isEmpty)
        #expect(Self.assignments("SET @x = 1, @@session.sql_log_bin = 0").map(\.name) == ["SQL_LOG_BIN"])
    }

    @Test("A comma inside parentheses or a string does not separate two elements")
    func valuesKeepTheirCommas() {
        #expect(Self.assignments("SET a = f(1, 2), sql_log_bin = 0").map(\.name) == ["A", "SQL_LOG_BIN"])
        #expect(Self.assignments("SET a = 'x,y', sql_log_bin = 0").map(\.name) == ["A", "SQL_LOG_BIN"])
    }

    @Test("The GTID line a mysqldump writes reads through its conditional comment")
    func gtidPurgedLineIsRead() {
        let read = Self.assignments("SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ 'ca7aa847:1-8'")
        #expect(read.count == 1)
        #expect(read.first?.name == "GTID_PURGED")
        #expect(read.first?.scope == .global)
    }

    @Test("MariaDB's SET STATEMENT stops at FOR")
    func setStatementStopsAtFor() {
        #expect(Self.assignments("SET STATEMENT gtid_domain_id = 3 FOR INSERT INTO t VALUES (1)")
            .map(\.name) == ["GTID_DOMAIN_ID"])
        #expect(Self.assignments("SET STATEMENT a = 1, b = 2 FOR INSERT INTO t VALUES (1)")
            .map(\.name) == ["A", "B"])
    }

    @Test("A reader that does not read the list stops after the first element")
    func firstElementOnly() {
        #expect(Self.assignments("SET NAMES utf8mb4, sql_log_bin = 0", readsList: false).isEmpty)
        #expect(Self.assignments("SET autocommit = 0, sql_log_bin = 0", readsList: false).map(\.name) == ["AUTOCOMMIT"])
    }

    @Test("MySQL carries the last scope keyword across the elements that follow it")
    func scopeCarriesAcrossTheList() {
        let read = Self.assignments("SET GLOBAL read_only = 1, gtid_mode = ON")
        #expect(read.map(\.name) == ["READ_ONLY", "GTID_MODE"])
        #expect(read.allSatisfy { $0.scope == .global })
    }
}
