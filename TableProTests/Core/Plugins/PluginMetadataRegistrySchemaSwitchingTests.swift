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
    private func snapshot(forTypeId typeId: String) -> PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: typeId)
    }

    // MARK: - SQL Server

    @Test("SQL Server supports schema switching")
    func sqlServerSupportsSchemaSwitching() {
        guard let snap = snapshot(forTypeId: "SQL Server") else {
            Issue.record("Registry default for SQL Server missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == true)
    }

    @Test("SQL Server post-connect actions restore last schema")
    func sqlServerRestoresLastSchema() {
        guard let snap = snapshot(forTypeId: "SQL Server") else {
            Issue.record("Registry default for SQL Server missing")
            return
        }
        #expect(snap.postConnectActions.contains(.selectSchemaFromLastSession))
    }

    @Test("SQL Server post-connect actions still restore last database")
    func sqlServerRestoresLastDatabase() {
        guard let snap = snapshot(forTypeId: "SQL Server") else {
            Issue.record("Registry default for SQL Server missing")
            return
        }
        #expect(snap.postConnectActions.contains(.selectDatabaseFromLastSession))
    }

    // MARK: - Oracle

    @Test("Oracle supports schema switching")
    func oracleSupportsSchemaSwitching() {
        guard let snap = snapshot(forTypeId: "Oracle") else {
            Issue.record("Registry default for Oracle missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == true)
    }

    @Test("Oracle post-connect actions restore last schema")
    func oracleRestoresLastSchema() {
        guard let snap = snapshot(forTypeId: "Oracle") else {
            Issue.record("Registry default for Oracle missing")
            return
        }
        #expect(snap.postConnectActions.contains(.selectSchemaFromLastSession))
    }

    // MARK: - PostgreSQL (regression for the working reference)

    @Test("PostgreSQL supports schema switching")
    func postgreSQLSupportsSchemaSwitching() {
        guard let snap = snapshot(forTypeId: "PostgreSQL") else {
            Issue.record("Registry default for PostgreSQL missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == true)
    }

    // MARK: - Negative cases (engines without schemas)

    @Test("MySQL does not support schema switching")
    func mysqlDoesNotSupportSchemaSwitching() {
        guard let snap = snapshot(forTypeId: "MySQL") else {
            Issue.record("Registry default for MySQL missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == false)
    }

    @Test("SQLite does not support schema switching")
    func sqliteDoesNotSupportSchemaSwitching() {
        guard let snap = snapshot(forTypeId: "SQLite") else {
            Issue.record("Registry default for SQLite missing")
            return
        }
        #expect(snap.capabilities.supportsSchemaSwitching == false)
    }

    // MARK: - Cross-component consistency

    @Test("Quick Switcher allowlist agrees with registry capability flag")
    func quickSwitcherAllowlistMatchesRegistry() {
        let typesThatShouldSupportSchemas = ["PostgreSQL", "Redshift", "Oracle", "SQL Server"]
        for typeId in typesThatShouldSupportSchemas {
            guard let snap = snapshot(forTypeId: typeId) else {
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
