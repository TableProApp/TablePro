//
//  TiDBCheckConstraintsTests.swift
//  TableProTests
//
//  Each statement is SHOW CREATE TABLE output measured on TiDB 7.5.1 and 8.5.1.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("TiDB check constraints")
struct TiDBCheckConstraintsTests {
    @Test("7.5 prints constraints unindented, and each expression matches CHECK_CLAUSE")
    func tidb75() {
        let sql = """
            CREATE TABLE `t` (
              `id` int(11) NOT NULL,
              `n` int(11) DEFAULT NULL,
              `m` int(11) DEFAULT NULL,
              PRIMARY KEY (`id`) /*T![clustered_index] CLUSTERED */,
            CONSTRAINT `ck_n` CHECK ((`n` > 0)),
            CONSTRAINT `t_chk_1` CHECK ((`m` < 10))
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin
            """
        let checks = TiDBCheckConstraints.parse(createTable: sql)
        #expect(checks.map(\.name) == ["ck_n", "t_chk_1"])
        #expect(checks.map(\.expression) == ["(`n` > 0)", "(`m` < 10)"])
    }

    @Test("Quotes, commas and parentheses inside a name or literal do not split the constraint")
    func tidb85QuotedText() {
        let sql = """
            CREATE TABLE `w(x` (
              `s` varchar(10) DEFAULT NULL,
              CONSTRAINT `c,1` CHECK ((`s` != _utf8mb4'a,(b'' \\\\ )')) /*!80016 NOT ENFORCED */,
              CONSTRAINT `q``t` CHECK ((length(`s`) > 1))
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin
            """
        let checks = TiDBCheckConstraints.parse(createTable: sql)
        #expect(checks.map(\.name) == ["c,1", "q`t"])
        #expect(checks.map(\.expression) == ["(`s` != _utf8mb4'a,(b'' \\\\ )')", "(length(`s`) > 1)"])
    }

    @Test("A table without checks has none, and a column named like the keyword is not one")
    func noChecks() {
        let sql = """
            CREATE TABLE `t` (
              `constraint` int DEFAULT NULL,
              `check` varchar(3) DEFAULT '(,)'
            ) ENGINE=InnoDB
            """
        #expect(TiDBCheckConstraints.parse(createTable: sql).isEmpty)
    }
}
