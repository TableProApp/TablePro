//
//  MySQLCheckConstraintsTests.swift
//  TableProTests
//
//  Each statement is SHOW CREATE TABLE output measured on TiDB 7.5.1, 8.5.1 and MariaDB 10.2.21.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MySQL check constraints")
struct MySQLCheckConstraintsTests {
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
        let checks = MySQLCheckConstraints.parse(createTable: sql)
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
        let checks = MySQLCheckConstraints.parse(createTable: sql)
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
        #expect(MySQLCheckConstraints.parse(createTable: sql).isEmpty)
    }

    @Test("MariaDB 10.2.21 enforces CHECK and prints it, so SHOW CREATE TABLE is the read")
    func mariadbCreateTableParse() {
        let sql = """
            CREATE TABLE `t` (
              `x` int(11) DEFAULT NULL CHECK (`x` <> 5),
              CONSTRAINT `c` CHECK (`x` > 0)
            ) ENGINE=InnoDB DEFAULT CHARSET=latin1
            """
        let checks = MySQLCheckConstraints.parse(createTable: sql)
        #expect(checks.map(\.name) == ["c"])
        #expect(checks.map(\.expression) == ["`x` > 0"])
    }

    @Test("MySQL reads the catalog from 8.0.16 and has nothing to read below it")
    func mysqlSource() {
        let unavailable = ["5.5.62", "5.6.51", "5.7.44", "8.0.15"]
        for banner in unavailable {
            #expect(MySQLCheckConstraints.source(banner: banner, flavor: .mysql) == .unavailable)
        }
        for banner in ["8.0.16", "8.0.19", "8.4.11"] {
            #expect(MySQLCheckConstraints.source(banner: banner, flavor: .mysql) == .informationSchema)
        }
    }

    @Test("MariaDB enforces from 10.2.1 but catalogues only from 10.2.22 and 10.3.10")
    func mariadbSource() {
        for banner in ["10.0.38-MariaDB", "10.1.48-MariaDB-1~bionic"] {
            #expect(MySQLCheckConstraints.source(banner: banner, flavor: .mariadb) == .unavailable)
        }
        for banner in ["10.2.6-MariaDB", "10.2.21-MariaDB", "10.3.0-MariaDB", "10.3.9-MariaDB"] {
            #expect(MySQLCheckConstraints.source(banner: banner, flavor: .mariadb) == .createTableStatement)
        }
        for banner in ["10.2.22-MariaDB", "10.3.10-MariaDB", "10.6.28-MariaDB-ubu2204", "11.4.13-MariaDB"] {
            #expect(MySQLCheckConstraints.source(banner: banner, flavor: .mariadb) == .informationSchema)
        }
    }

    @Test("TiDB, OceanBase and Databend answer from their own version, not the banner")
    func variantSources() {
        let banner = "8.0.11-TiDB-v7.5.1"
        #expect(MySQLCheckConstraints.source(
            banner: banner, flavor: .tidb(version: MySQLEngineVersion(major: 7, minor: 1, patch: 5))
        ) == .unavailable)
        #expect(MySQLCheckConstraints.source(
            banner: banner, flavor: .tidb(version: MySQLEngineVersion(major: 7, minor: 5, patch: 1))
        ) == .createTableStatement)
        #expect(MySQLCheckConstraints.source(banner: banner, flavor: .tidb(version: nil)) == .unavailable)
        #expect(MySQLCheckConstraints.source(
            banner: "5.7.25", flavor: .oceanbase(version: MySQLEngineVersion(major: 3, minor: 1, patch: 4))
        ) == .unavailable)
        #expect(MySQLCheckConstraints.source(
            banner: "5.7.25", flavor: .oceanbase(version: MySQLEngineVersion(major: 4, minor: 0, patch: 0))
        ) == .informationSchema)
        #expect(MySQLCheckConstraints.source(banner: "8.0.90-v1.2.3-nightly", flavor: .databend) == .databendCatalog)
    }

    @Test("A server too old to keep a CHECK says so, and one whose version is unknown says nothing")
    func refusal() {
        #expect(MySQLCheckConstraints.refusal(banner: "5.7.44", flavor: .mysql)
            == "Check constraints need MySQL 8.0.16 or later.")
        #expect(MySQLCheckConstraints.refusal(banner: "10.1.48-MariaDB", flavor: .mariadb)
            == "Check constraints need MariaDB 10.2.1 or later.")
        #expect(MySQLCheckConstraints.refusal(banner: "8.0.16", flavor: .mysql) == nil)
        #expect(MySQLCheckConstraints.refusal(banner: "10.2.21-MariaDB", flavor: .mariadb) == nil)
        #expect(MySQLCheckConstraints.refusal(
            banner: "8.0.11-TiDB-v7.1.5", flavor: .tidb(version: MySQLEngineVersion(major: 7, minor: 1, patch: 5))
        ) == "Check constraints need TiDB 7.2 or later.")
    }

    /// A disconnect clears the banner and resets the flavor to `.mysql`, and the app keeps that
    /// handle installed across the reconnect. Reading that as "too old" hid the tab on MariaDB 11.
    @Test("An unread banner refuses nothing and edits nothing")
    func unknownBanner() {
        #expect(MySQLCheckConstraints.refusal(banner: nil, flavor: .mysql) == nil)
        #expect(MySQLCheckConstraints.refusal(banner: "unknown", flavor: .mysql) == nil)
        #expect(MySQLCheckConstraints.refusal(banner: nil, flavor: .mariadb) == nil)
        #expect(!MySQLCheckConstraints.supportsEditing(banner: nil, flavor: .mysql))
        #expect(!MySQLCheckConstraints.supportsEditing(banner: "unknown", flavor: .mysql))
        #expect(MySQLCheckConstraints.source(banner: nil, flavor: .mysql) == .unavailable)
    }

    @Test("Editing is offered exactly where the server keeps the clause")
    func supportsEditing() {
        #expect(!MySQLCheckConstraints.supportsEditing(banner: "5.7.44", flavor: .mysql))
        #expect(MySQLCheckConstraints.supportsEditing(banner: "8.0.16", flavor: .mysql))
        #expect(!MySQLCheckConstraints.supportsEditing(banner: "10.1.48-MariaDB", flavor: .mariadb))
        #expect(MySQLCheckConstraints.supportsEditing(banner: "10.2.6-MariaDB", flavor: .mariadb))
    }

    @Test("MySQL 8.0.16 to 8.0.18 takes DROP CHECK, and MariaDB never does")
    func dropKeyword() {
        #expect(MySQLCheckConstraints.dropStatement(
            quotedTable: "`t`", quotedName: "`c`", banner: "8.0.16", flavor: .mysql
        ) == "ALTER TABLE `t` DROP CHECK `c`")
        #expect(MySQLCheckConstraints.dropStatement(
            quotedTable: "`t`", quotedName: "`c`", banner: "8.0.19", flavor: .mysql
        ) == "ALTER TABLE `t` DROP CONSTRAINT `c`")
        #expect(MySQLCheckConstraints.dropStatement(
            quotedTable: "`t`", quotedName: "`c`", banner: "8.4.11", flavor: .mysql
        ) == "ALTER TABLE `t` DROP CONSTRAINT `c`")
        #expect(MySQLCheckConstraints.dropStatement(
            quotedTable: "`t`", quotedName: "`c`", banner: "10.6.28-MariaDB", flavor: .mariadb
        ) == "ALTER TABLE `t` DROP CONSTRAINT `c`")
    }
}
