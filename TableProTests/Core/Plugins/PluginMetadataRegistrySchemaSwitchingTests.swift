//
//  PluginMetadataRegistrySchemaSwitchingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct PluginMetadataRegistrySchemaSwitchingTests {
    private func snapshot(forRegisteredTypeId typeId: String) -> PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: typeId)
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
