//
//  MySQLServerFlavorTests.swift
//  TableProTests
//

import TableProPluginKit
import Testing

@Suite("MySQL server flavor")
struct MySQLServerFlavorTests {
    private static let databendBanner = "8.0.90-v1.2.881-ca29960f5c(rust-1.94.0-nightly-2026-04-17T02:30:29.281093406Z)"

    @Test("The banner names the engine", arguments: [
        ("8.0.36", MySQLServerFlavor.mysql),
        ("8.0.36-28", .mysql),
        ("10.6.16-MariaDB", .mariadb),
        ("11.4.2-MariaDB-log", .mariadb),
        ("8.0.11-TiDB-v7.5.1", .tidb(version: MySQLEngineVersion(major: 7, minor: 5, patch: 1))),
        ("8.0.11-TiDB-v8.5.1", .tidb(version: MySQLEngineVersion(major: 8, minor: 5, patch: 1))),
        (databendBanner, .databend)
    ])
    func bannerNamesTheEngine(banner: String, expected: MySQLServerFlavor) {
        #expect(MySQLServerFlavor.fromBanner(banner) == expected)
    }

    @Test("No banner reads as MySQL")
    func missingBannerIsMySQL() {
        #expect(MySQLServerFlavor.fromBanner(nil) == .mysql)
    }

    @Test("TiDB's release information carries the real version when the banner was overridden")
    func tidbReleaseInformation() {
        let info = "Release Version: v7.5.1\nEdition: Community\nGit Commit Hash: 7d16cc79"
        #expect(MySQLServerFlavor.tidbVersion(fromReleaseInfo: info) == MySQLEngineVersion(major: 7, minor: 5, patch: 1))
        #expect(MySQLServerFlavor.tidbVersion(fromReleaseInfo: "8.0.36") == nil)
    }

    @Test("A TiDB or Databend connection whose banner does not say so is confirmed with a query")
    func probesOnlyWhenTheBannerIsSilent() {
        #expect(MySQLFlavorResolution.needsTiDBVersionProbe(banner: "8.0.35", variant: "TiDB"))
        #expect(!MySQLFlavorResolution.needsTiDBVersionProbe(banner: "8.0.11-TiDB-v7.5.1", variant: "TiDB"))
        #expect(!MySQLFlavorResolution.needsTiDBVersionProbe(banner: "8.0.35", variant: nil))
        #expect(MySQLFlavorResolution.needsDatabendProbe(banner: "8.0.36", variant: "Databend"))
        #expect(!MySQLFlavorResolution.needsDatabendProbe(banner: Self.databendBanner, variant: "Databend"))
    }

    @Test("System databases are the exact spellings each engine reports")
    func systemDatabases() {
        #expect(MySQLServerFlavor.mysql.systemDatabaseNames == ["information_schema", "mysql", "performance_schema", "sys"])
        #expect(MySQLServerFlavor.tidb(version: nil).systemDatabaseNames == [
            "INFORMATION_SCHEMA", "METRICS_SCHEMA", "PERFORMANCE_SCHEMA", "mysql", "sys"
        ])
        #expect(MySQLServerFlavor.databend.systemDatabaseNames == ["information_schema", "system"])
    }

    @Test("TiDB and Databend offer only the maintenance they support")
    func maintenanceOperations() {
        #expect(MySQLServerFlavor.mysql.maintenanceOperations.count == 4)
        #expect(MySQLServerFlavor.tidb(version: nil).maintenanceOperations == ["ANALYZE TABLE"])
        #expect(MySQLServerFlavor.databend.maintenanceOperations == ["ANALYZE TABLE"])
    }

    @Test("TiDB sequences cannot be browsed, so they are not listed as tables")
    func sequences() {
        #expect(!MySQLServerFlavor.tidb(version: nil).listsSequencesAsTables)
        #expect(MySQLServerFlavor.mariadb.listsSequencesAsTables)
    }

    @Test("Only TiDB ends an idle session that a KILL QUERY reaches, so a finished read is never killed there")
    func idleKillDropsOnlyTiDBSessions() {
        #expect(MySQLServerFlavor.tidb(version: nil).dropsIdleSessionOnKillQuery)
        #expect(!MySQLServerFlavor.mysql.dropsIdleSessionOnKillQuery)
        #expect(!MySQLServerFlavor.mariadb.dropsIdleSessionOnKillQuery)
        #expect(!MySQLServerFlavor.databend.dropsIdleSessionOnKillQuery)
    }

    @Test("Only Databend refuses server-side prepare")
    func serverSidePrepare() {
        #expect(!MySQLServerFlavor.databend.preparesOnServer)
        #expect(MySQLServerFlavor.tidb(version: nil).preparesOnServer)
        #expect(MySQLServerFlavor.mysql.preparesOnServer)
    }

    @Test("A read-write transaction declares the access mode so a read-only session default is overridden")
    func readWriteDeclaresAccessMode() {
        #expect(MySQLServerFlavor.mysql.beginTransactionStatement(mode: .readWrite) == "START TRANSACTION READ WRITE")
        #expect(MySQLServerFlavor.tidb(version: nil).beginTransactionStatement(mode: .readWrite) == "START TRANSACTION READ WRITE")
    }

    @Test("A server-default transaction inherits the session access mode")
    func serverDefaultInheritsSessionMode() {
        #expect(MySQLServerFlavor.mysql.beginTransactionStatement(mode: .serverDefault) == "START TRANSACTION")
    }

    @Test("Databend opens a transaction with BEGIN, the only form it does not ignore")
    func databendBegins() {
        #expect(MySQLServerFlavor.databend.beginTransactionStatement(mode: .readWrite) == "BEGIN")
        #expect(MySQLServerFlavor.databend.beginTransactionStatement(mode: .serverDefault) == "BEGIN")
    }

    @Test("Each engine names its own statement timeout", arguments: [
        (MySQLServerFlavor.mariadb, 0, "SET SESSION max_statement_time = 0"),
        (.mariadb, 30, "SET SESSION max_statement_time = 30"),
        (.mysql, 0, "SET SESSION max_execution_time = 0"),
        (.mysql, 30, "SET SESSION max_execution_time = 30000"),
        (.tidb(version: nil), 30, "SET SESSION max_execution_time = 30000"),
        (.databend, 30, "SET max_execute_time_in_seconds = 30")
    ])
    func queryTimeout(flavor: MySQLServerFlavor, seconds: Int, expected: String) {
        #expect(flavor.queryTimeoutStatement(seconds: seconds) == expected)
    }

    @Test("A killed statement reads as the interruption each engine reports")
    func killInterruption() {
        #expect(MySQLServerFlavor.mysql.isInterruptedByKill(errno: 1_317, message: "Query execution was interrupted"))
        #expect(!MySQLServerFlavor.mysql.isInterruptedByKill(errno: 1_105, message: "AbortedQuery"))
        #expect(MySQLServerFlavor.databend.isInterruptedByKill(
            errno: 1_105, message: "AbortedQuery. Code: 1043, Text = Aborted query, because the server is shutting down or the query was killed.."
        ))
        #expect(!MySQLServerFlavor.databend.isInterruptedByKill(errno: 1_105, message: "SyntaxException. Code: 1005"))
    }

    @Test("TiDB kills by its 64-bit connection id and Databend by its session id")
    func killStatements() {
        let tidb = MySQLServerFlavor.tidb(version: nil).killTarget(connectionIdentifier: "2199023255571")
        #expect(tidb.statement(threadId: 19) == "KILL TIDB QUERY 2199023255571")

        let databend = MySQLServerFlavor.databend.killTarget(connectionIdentifier: "1f7e5199-119f-484a-aaff-e8d5143a7979")
        #expect(databend.statement(threadId: 89) == "KILL QUERY '1f7e5199-119f-484a-aaff-e8d5143a7979'")

        let mysql = MySQLServerFlavor.mysql.killTarget(connectionIdentifier: "42")
        #expect(mysql.statement(threadId: 42) == "KILL QUERY 42")
        #expect(mysql.statement(threadId: 0) == nil)
    }

    @Test("A connection id that cannot be read falls back to the handshake thread id")
    func killFallsBackToThreadId() {
        #expect(MySQLServerFlavor.tidb(version: nil).killTarget(connectionIdentifier: nil) == .threadId)
        #expect(MySQLServerFlavor.tidb(version: nil).killTarget(connectionIdentifier: "not-a-number") == .threadId)
        #expect(MySQLServerFlavor.databend.killTarget(connectionIdentifier: "") == .threadId)
    }

    @Test("CHECK constraints are read on TiDB from 7.2, whatever the 8.0.11 banner says")
    func tidbCheckConstraints() {
        let banner = "8.0.11-TiDB-v7.5.1"
        #expect(MySQLServerVersion.hasCheckConstraints(
            banner: banner, flavor: .tidb(version: MySQLEngineVersion(major: 7, minor: 5, patch: 1))
        ))
        #expect(!MySQLServerVersion.hasCheckConstraints(
            banner: banner, flavor: .tidb(version: MySQLEngineVersion(major: 7, minor: 1, patch: 5))
        ))
        #expect(!MySQLServerVersion.hasCheckConstraints(banner: banner, flavor: .tidb(version: nil)))
        #expect(!MySQLServerVersion.hasCheckConstraints(banner: Self.databendBanner, flavor: .databend))
    }

    @Test("Databend's 8.0.90 banner does not unlock MySQL catalog columns it lacks")
    func databendGenerationExpression() {
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: Self.databendBanner, flavor: .databend))
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "8.0.11-TiDB-v7.5.1", flavor: .tidb(version: nil)))
    }
}
