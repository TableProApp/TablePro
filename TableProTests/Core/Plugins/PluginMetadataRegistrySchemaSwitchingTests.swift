//
//  PluginMetadataRegistrySchemaSwitchingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("PluginMetadataRegistry schema switching")
struct PluginMetadataRegistrySchemaSwitchingTests {
    private func snapshot(forRegisteredTypeId typeId: String) -> PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: typeId)
    }

    // MARK: - SQL Server

    @Test("SQL Server supports schema switching")
    func sqlServerSupportsSchemaSwitching() {
        guard let snap = snapshot(forRegisteredTypeId: "SQL Server") else {
            Issue.record("Registry default for SQL Server missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == true)
    }

    @Test("SQL Server post-connect actions restore last schema")
    func sqlServerRestoresLastSchema() {
        guard let snap = snapshot(forRegisteredTypeId: "SQL Server") else {
            Issue.record("Registry default for SQL Server missing")
            return
        }
        #expect(snap.postConnectActions.contains(.selectSchemaFromLastSession))
    }

    @Test("SQL Server post-connect actions still restore last database")
    func sqlServerRestoresLastDatabase() {
        guard let snap = snapshot(forRegisteredTypeId: "SQL Server") else {
            Issue.record("Registry default for SQL Server missing")
            return
        }
        #expect(snap.postConnectActions.contains(.selectDatabaseFromLastSession))
    }

    // MARK: - Oracle

    @Test("Oracle supports schema switching")
    func oracleSupportsSchemaSwitching() {
        guard let snap = snapshot(forRegisteredTypeId: "Oracle") else {
            Issue.record("Registry default for Oracle missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == true)
    }

    @Test("Oracle post-connect actions restore last schema")
    func oracleRestoresLastSchema() {
        guard let snap = snapshot(forRegisteredTypeId: "Oracle") else {
            Issue.record("Registry default for Oracle missing")
            return
        }
        #expect(snap.postConnectActions.contains(.selectSchemaFromLastSession))
    }

    // MARK: - Dameng

    @Test("Dameng supports schema switching without TLS")
    func damengSupportsSchemaSwitching() {
        guard let snap = snapshot(forRegisteredTypeId: "Dameng") else {
            Issue.record("Registry default for Dameng missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == true)
        #expect(snap.capabilities.supportsSSL == false)
        #expect(snap.postConnectActions.contains(.selectSchemaFromLastSession))
    }

    @Test("Dameng publishes DM8 typing suggestions")
    func damengPublishesTypingSuggestions() {
        guard let snap = snapshot(forRegisteredTypeId: "Dameng") else {
            Issue.record("Registry default for Dameng missing")
            return
        }
        let labels = Set(snap.editor.statementCompletions.map(\.label))
        #expect(labels.isSuperset(of: ["SET SCHEMA", "CREATE SCHEMA", "EXPLAIN", "CONNECT BY"]))
        #expect(snap.editor.sqlDialect?.functions.contains("NVL") == true)
        #expect(snap.editor.sqlDialect?.dataTypes.contains("VARCHAR2") == true)
        #expect(snap.editor.sqlDialect?.dataTypes.contains("XMLTYPE") == false)
        #expect(snap.editor.sqlDialect?.functions.contains("DBMS_RANDOM.VALUE") == false)
    }

    // MARK: - DuckDB

    @Test("DuckDB supports schema switching")
    func duckDBSupportsSchemaSwitching() {
        guard let snap = snapshot(forRegisteredTypeId: "DuckDB") else {
            Issue.record("Registry default for DuckDB missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == true)
    }

    @Test("DuckDB post-connect actions restore last schema")
    func duckDBRestoresLastSchema() {
        guard let snap = snapshot(forRegisteredTypeId: "DuckDB") else {
            Issue.record("Registry default for DuckDB missing")
            return
        }
        #expect(snap.postConnectActions.contains(.selectSchemaFromLastSession))
    }

    /// DuckDB's default schema is `main`. Inheriting PostgreSQL's `public` made every
    /// table in the default schema render as `main.name` and broke export preselection.
    @Test("DuckDB's default schema is main")
    func duckDBDefaultSchemaIsMain() {
        #expect(snapshot(forRegisteredTypeId: "DuckDB")?.schema.defaultSchemaName == "main")
    }

    /// `information_schema` and `pg_catalog` are schemas of DuckDB's `system` catalog,
    /// not databases. The system databases are `system` and `temp`.
    @Test("DuckDB's system databases are its built-in catalogs")
    func duckDBSystemDatabases() {
        let names = snapshot(forRegisteredTypeId: "DuckDB")?.schema.systemDatabaseNames ?? []
        #expect(Set(names) == ["system", "temp"])
    }

    // MARK: - PostgreSQL (regression for the working reference)

    @Test("PostgreSQL supports schema switching")
    func postgreSQLSupportsSchemaSwitching() {
        guard let snap = snapshot(forRegisteredTypeId: "PostgreSQL") else {
            Issue.record("Registry default for PostgreSQL missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == true)
    }

    // MARK: - Negative cases (engines without schemas)

    @Test("MySQL does not support schema switching")
    func mysqlDoesNotSupportSchemaSwitching() {
        guard let snap = snapshot(forRegisteredTypeId: "MySQL") else {
            Issue.record("Registry default for MySQL missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == false)
    }

    @Test("SQLite does not support schema switching")
    func sqliteDoesNotSupportSchemaSwitching() {
        guard let snap = snapshot(forRegisteredTypeId: "SQLite") else {
            Issue.record("Registry default for SQLite missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == false)
    }

    // MARK: - Cross-component consistency

    @Test("Quick Switcher allowlist agrees with registry capability flag")
    func quickSwitcherAllowlistMatchesRegistry() {
        let typesThatShouldSupportSchemas = [
            "PostgreSQL", "Redshift", "Oracle", "Dameng", "SQL Server", "DuckDB",
        ]
        for typeId in typesThatShouldSupportSchemas {
            guard let snap = snapshot(forRegisteredTypeId: typeId) else {
                Issue.record("Registry default for \(typeId) missing")
                continue
            }
            #expect(
                snap.capabilities.supportsSchemaSwitching == true,
                "\(typeId) is in the documented schema-aware engine set but registry has supportsSchemaSwitching = false"
            )
        }
    }
}
