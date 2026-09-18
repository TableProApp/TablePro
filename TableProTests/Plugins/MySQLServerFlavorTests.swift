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

    /// Measured with the app's own libmariadb against MySQL 5.5.62 and 8.4.11, MariaDB 5.5.64 and
    /// 11.4.13 and TiDB v8.5.1. Databend and OceanBase are unmeasured, and an engine that may never
    /// set the flag must not be read as reporting no transaction.
    @Test("Only the flavours measured to carry the session status flags report them")
    func statusFlagReportingIsPerFlavor() {
        #expect(MySQLServerFlavor.mysql.reportsSessionStatusFlags)
        #expect(MySQLServerFlavor.mariadb.reportsSessionStatusFlags)
        #expect(MySQLServerFlavor.tidb(version: nil).reportsSessionStatusFlags)
        #expect(MySQLServerFlavor.databend.reportsSessionStatusFlags == false)
        #expect(MySQLServerFlavor.oceanbase(version: nil).reportsSessionStatusFlags == false)
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

    @Test("OceanBase's handshake banner is a plain MySQL version, direct or through OBProxy")
    func oceanbaseBannerIsPlainMySQL() {
        #expect(MySQLServerFlavor.fromBanner("5.7.25") == .mysql)
        #expect(MySQLServerFlavor.fromBanner("5.6.25") == .mysql)
    }

    @Test("The version comment opens with OceanBase and its version", arguments: [
        (
            "OceanBase_CE 4.4.2.1 (r101000022026050611-8cf64ed50606966fd5c29f47265cf557d97ea776) (Built May  6 2026 12:29:53)",
            MySQLEngineVersion(major: 4, minor: 4, patch: 2)
        ),
        (
            "OceanBase_CE 4.0.0.0 (r100000272022110114-6af7f9ae79cd0ecbafd4b1b88e2886ccdba0c3be) (Built Nov  1 2022 14:53:48)",
            MySQLEngineVersion(major: 4, minor: 0, patch: 0)
        ),
        ("OceanBase 4.2.5.4 (r1-abc) (Built Jul 15 2025 15:31:08)", MySQLEngineVersion(major: 4, minor: 2, patch: 5)),
        ("OceanBase 3.1.4 (r1-abc) (Built Jul 15 2022 11:45:14)", MySQLEngineVersion(major: 3, minor: 1, patch: 4))
    ])
    func oceanbaseVersionComment(comment: String, expected: MySQLEngineVersion) {
        #expect(
            MySQLFlavorResolution.oceanbaseFlavor(versionComment: comment, serverVersion: nil)
                == .oceanbase(version: expected)
        )
    }

    @Test("The edition name is matched without regard to case")
    func versionCommentIgnoresCase() {
        #expect(
            MySQLFlavorResolution.oceanbaseFlavor(versionComment: "oceanbase_ce 4.4.2.1 (r1-abc)", serverVersion: nil)
                == .oceanbase(version: MySQLEngineVersion(major: 4, minor: 4, patch: 2))
        )
    }

    @Test("A comment in an unknown format falls back to the OceanBase suffix of @@version", arguments: [
        ("5.7.25-OceanBase_CE-v4.4.2.1", MySQLEngineVersion(major: 4, minor: 4, patch: 2)),
        ("5.7.25-OceanBase-v4.2.5.4", MySQLEngineVersion(major: 4, minor: 2, patch: 5))
    ])
    func serverVersionFallback(serverVersion: String, expected: MySQLEngineVersion) {
        #expect(
            MySQLFlavorResolution.oceanbaseFlavor(versionComment: "OceanBase Cloud build", serverVersion: serverVersion)
                == .oceanbase(version: expected)
        )
        #expect(
            MySQLFlavorResolution.oceanbaseFlavor(versionComment: nil, serverVersion: serverVersion)
                == .oceanbase(version: expected)
        )
    }

    @Test("A comment that only mentions OceanBase, or names no version, is not OceanBase", arguments: [
        "MySQL Community Server - GPL",
        "mariadb.org binary distribution",
        "",
        "Percona Server, compatible with OceanBase 4.2.1",
        "OceanBase",
        "OceanBaseX 4.2.1",
        "5.7.25-OceanBase_CE-v4.4.2.1"
    ])
    func notOceanBase(comment: String) {
        #expect(MySQLFlavorResolution.oceanbaseFlavor(versionComment: comment, serverVersion: "8.4.11") == nil)
    }

    @Test("A probe that returned nothing is not OceanBase")
    func missingIdentityIsNotOceanBase() {
        #expect(MySQLFlavorResolution.oceanbaseFlavor(versionComment: nil, serverVersion: nil) == nil)
        #expect(MySQLFlavorResolution.oceanbaseFlavor(versionComment: nil, serverVersion: "5.7.25") == nil)
    }

    @Test("System databases are the exact spellings each engine reports")
    func systemDatabases() {
        #expect(MySQLServerFlavor.mysql.systemDatabaseNames == ["information_schema", "mysql", "performance_schema", "sys"])
        #expect(MySQLServerFlavor.tidb(version: nil).systemDatabaseNames == [
            "INFORMATION_SCHEMA", "METRICS_SCHEMA", "PERFORMANCE_SCHEMA", "mysql", "sys"
        ])
        #expect(MySQLServerFlavor.databend.systemDatabaseNames == ["information_schema", "system"])
        #expect(MySQLServerFlavor.oceanbase(version: nil).systemDatabaseNames == [
            "information_schema", "mysql", "oceanbase", "__recyclebin", "__public", "SYS", "LBACSYS", "ORAAUDITOR"
        ])
        #expect(!MySQLServerFlavor.oceanbase(version: nil).systemDatabaseNames.contains("test"))
        #expect(!MySQLServerFlavor.oceanbase(version: nil).systemDatabaseNames.contains("ocs"))
    }

    @Test("TiDB and Databend offer only the maintenance they support")
    func maintenanceOperations() {
        #expect(MySQLServerFlavor.mysql.maintenanceOperations.count == 4)
        #expect(MySQLServerFlavor.tidb(version: nil).maintenanceOperations.map(\.name) == ["ANALYZE TABLE"])
        #expect(MySQLServerFlavor.databend.maintenanceOperations.map(\.name) == ["ANALYZE TABLE"])
    }

    @Test("OceanBase offers ANALYZE TABLE only where its grammar takes the bare form", arguments: [
        (MySQLEngineVersion?.none, [String]()),
        (MySQLEngineVersion(major: 4, minor: 0, patch: 0), []),
        (MySQLEngineVersion(major: 4, minor: 2, patch: 1), []),
        (MySQLEngineVersion(major: 4, minor: 2, patch: 2), ["ANALYZE TABLE"]),
        (MySQLEngineVersion(major: 4, minor: 4, patch: 2), ["ANALYZE TABLE"])
    ])
    func oceanbaseMaintenance(version: MySQLEngineVersion?, expected: [String]) {
        #expect(MySQLServerFlavor.oceanbase(version: version).maintenanceOperations.map(\.name) == expected)
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
        #expect(!MySQLServerFlavor.oceanbase(version: nil).dropsIdleSessionOnKillQuery)
    }

    @Test("Only Databend refuses server-side prepare")
    func serverSidePrepare() {
        #expect(!MySQLServerFlavor.databend.preparesOnServer)
        #expect(MySQLServerFlavor.tidb(version: nil).preparesOnServer)
        #expect(MySQLServerFlavor.mysql.preparesOnServer)
        #expect(MySQLServerFlavor.oceanbase(version: nil).preparesOnServer)
    }

    @Test(
        "MySQL and MariaDB declare the access mode in a comment only 5.6.5 and later execute",
        arguments: [MySQLServerFlavor.mysql, .mariadb]
    )
    func readWriteDeclaresAccessModeForServersThatParseIt(flavor: MySQLServerFlavor) {
        #expect(flavor.beginTransactionStatement(mode: .readWrite) == "START TRANSACTION /*!50605 READ WRITE */")
    }

    @Test(
        "TiDB and OceanBase declare the access mode as plain syntax",
        arguments: [
            MySQLServerFlavor.tidb(version: nil),
            .tidb(version: MySQLEngineVersion(major: 8, minor: 5, patch: 0)),
            .oceanbase(version: nil),
            .oceanbase(version: MySQLEngineVersion(major: 4, minor: 3, patch: 5)),
        ]
    )
    func readWriteDeclaresAccessModeAsSyntax(flavor: MySQLServerFlavor) {
        #expect(flavor.beginTransactionStatement(mode: .readWrite) == "START TRANSACTION READ WRITE")
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
        (MySQLServerFlavor.mariadb, 0, ["SET SESSION max_statement_time = 0"]),
        (.mariadb, 30, ["SET SESSION max_statement_time = 30"]),
        (.mysql, 0, ["SET SESSION max_execution_time = 0"]),
        (.mysql, 30, ["SET SESSION max_execution_time = 30000"]),
        (.tidb(version: nil), 30, ["SET SESSION max_execution_time = 30000"]),
        (.databend, 30, ["SET max_execute_time_in_seconds = 30"])
    ])
    func queryTimeout(flavor: MySQLServerFlavor, seconds: Int, expected: [String]) {
        #expect(flavor.queryTimeoutStatements(seconds: seconds) == expected)
    }

    @Test("OceanBase moves its own query timeout and clears a global max_execution_time, one statement each")
    func oceanbaseQueryTimeout() {
        let flavor = MySQLServerFlavor.oceanbase(version: MySQLEngineVersion(major: 4, minor: 4, patch: 2))
        #expect(flavor.queryTimeoutStatements(seconds: 30) == [
            "SET SESSION ob_query_timeout = 30000000", "SET SESSION max_execution_time = 0"
        ])
        #expect(flavor.queryTimeoutStatements(seconds: 0) == [
            "SET SESSION ob_query_timeout = 3216672000000000", "SET SESSION max_execution_time = 0"
        ])
        #expect(MySQLServerFlavor.oceanbase(version: nil).queryTimeoutStatements(seconds: 0)
            == flavor.queryTimeoutStatements(seconds: 0))
    }

    @Test("A killed statement reads as the interruption each engine reports")
    func killInterruption() {
        #expect(MySQLServerFlavor.mysql.isInterruptedByKill(errno: 1_317, message: "Query execution was interrupted"))
        #expect(MySQLServerFlavor.oceanbase(version: nil).isInterruptedByKill(
            errno: 1_317, message: "Query execution was interrupted"
        ))
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

    @Test("OceanBase kills by the handshake thread id, which OBProxy maps to the server session")
    func oceanbaseKillsByThreadId() {
        let flavor = MySQLServerFlavor.oceanbase(version: nil)
        #expect(flavor.killTarget(connectionIdentifier: "3221613678") == .threadId)
        #expect(flavor.killTarget(connectionIdentifier: nil) == .threadId)
        #expect(flavor.killTarget(connectionIdentifier: nil).statement(threadId: 3_221_613_678) == "KILL QUERY 3221613678")
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
        #expect(MySQLCheckConstraints.source(
            banner: banner, flavor: .tidb(version: MySQLEngineVersion(major: 7, minor: 5, patch: 1))
        ) == .createTableStatement)
        #expect(MySQLCheckConstraints.source(
            banner: banner, flavor: .tidb(version: MySQLEngineVersion(major: 7, minor: 1, patch: 5))
        ) == .unavailable)
        #expect(MySQLCheckConstraints.source(banner: banner, flavor: .tidb(version: nil)) == .unavailable)
        #expect(MySQLCheckConstraints.source(
            banner: Self.databendBanner, flavor: .databend
        ) == .databendCatalog)
    }

    @Test("Databend's 8.0.90 banner does not unlock MySQL catalog columns it lacks")
    func databendGenerationExpression() {
        #expect(!MySQLServerVersion.hasGenerationExpression(banner: Self.databendBanner, flavor: .databend))
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "8.0.11-TiDB-v7.5.1", flavor: .tidb(version: nil)))
    }

    @Test("OceanBase reads CHECK constraints from 4.0 and generation expressions on every version", arguments: [
        (MySQLEngineVersion?.none, false),
        (MySQLEngineVersion(major: 3, minor: 1, patch: 4), false),
        (MySQLEngineVersion(major: 4, minor: 0, patch: 0), true),
        (MySQLEngineVersion(major: 4, minor: 4, patch: 2), true)
    ])
    func oceanbaseCatalogGates(version: MySQLEngineVersion?, readsCheckConstraints: Bool) {
        let flavor = MySQLServerFlavor.oceanbase(version: version)
        let source = MySQLCheckConstraints.source(banner: "5.7.25", flavor: flavor)
        #expect((source == .informationSchema) == readsCheckConstraints)
        #expect(MySQLServerVersion.hasGenerationExpression(banner: "5.7.25", flavor: flavor))
        #expect(!MySQLServerVersion.quotesColumnDefault(banner: "5.7.25", flavor: flavor))
    }

    /// A MySQL or MariaDB connection resolves its flavor from the banner, so it can land on MariaDB or TiDB, and
    /// every name those servers report has to be on its list, or the sidebar lists it as a user database.
    @Test("A MySQL or MariaDB connection lists what MySQL, MariaDB and TiDB report, except METRICS_SCHEMA")
    func mysqlTypeCoversEveryReachableFlavor() {
        let listed = Set(MySQLSystemDatabases.names(forVariant: nil))
        for flavor in [MySQLServerFlavor.mysql, .mariadb, .tidb(version: nil)] {
            let missing = Set(flavor.systemDatabaseNames).subtracting(listed).subtracting(["METRICS_SCHEMA"])
            #expect(missing.isEmpty, "\(flavor) reports \(missing.sorted()) that a MySQL connection does not list")
        }
    }

    @Test("A TiDB connection lists what TiDB reports, and what MySQL reports when the version probe fails")
    func tidbTypeCoversEveryReachableFlavor() {
        let listed = Set(MySQLSystemDatabases.names(forVariant: MySQLServerFlavor.tidbVariant))
        for flavor in [MySQLServerFlavor.tidb(version: nil), .mysql, .mariadb] {
            let missing = Set(flavor.systemDatabaseNames).subtracting(listed)
            #expect(missing.isEmpty, "\(flavor) reports \(missing.sorted()) that a TiDB connection does not list")
        }
    }

    /// Measured on MySQL 8.4 with lower_case_table_names 0: CREATE DATABASE succeeds for each of these.
    @Test("A name MySQL lets a user create is never a system database on a MySQL connection")
    func userCreatableNamesStayUserDatabases() {
        let listed = MySQLSystemDatabases.names(forVariant: nil)
        for name in ["METRICS_SCHEMA", "metrics_schema", "MYSQL", "SYS"] {
            #expect(!listed.contains(name), "\(name) is a database a MySQL user can create")
        }
    }

    @Test("Databend and OceanBase connections use their own server's list")
    func singleFlavorTypesUseTheirFlavor() {
        #expect(
            MySQLSystemDatabases.names(forVariant: MySQLServerFlavor.databendVariant)
                == MySQLServerFlavor.databend.systemDatabaseNames
        )
        #expect(
            MySQLSystemDatabases.names(forVariant: MySQLServerFlavor.oceanbaseVariant)
                == MySQLServerFlavor.oceanbase(version: nil).systemDatabaseNames
        )
    }
}
