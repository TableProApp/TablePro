//
//  PluginMetadataRegistrySystemDatabaseTests.swift
//  TableProTests
//
//  The registry's curated defaults are the pre-plugin-load classification and
//  must agree with what the PostgreSQL plugin reports once it registers.
//  Redshift shipped a disagreement that flipped which database was hidden
//  partway through loading the switcher (#1967).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("PluginMetadataRegistry system databases")
struct PluginMetadataRegistrySystemDatabaseTests {
    private func systemDatabaseNames(forTypeId typeId: String) -> [String]? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: typeId)?.schema.systemDatabaseNames
    }

    @Test("PostgreSQL default matches the plugin")
    func postgreSQLMatchesPlugin() {
        #expect(systemDatabaseNames(forTypeId: "PostgreSQL") == PostgreSQLSystemDatabases.postgreSQL)
    }

    @Test("PGlite default matches the plugin")
    func pgliteMatchesPlugin() {
        #expect(systemDatabaseNames(forTypeId: "PGlite") == PostgreSQLSystemDatabases.postgreSQL)
    }

    @Test("Redshift default matches the plugin")
    func redshiftMatchesPlugin() {
        #expect(systemDatabaseNames(forTypeId: "Redshift") == PostgreSQLSystemDatabases.redshift)
    }

    @Test("CockroachDB default matches the plugin")
    func cockroachMatchesPlugin() {
        #expect(systemDatabaseNames(forTypeId: "CockroachDB") == PostgreSQLSystemDatabases.cockroachDB)
    }

    @Test("No PostgreSQL-family engine hides its default landing database")
    func defaultLandingDatabasesStayVisible() {
        let defaults = [
            ("PostgreSQL", "postgres"),
            ("PGlite", "postgres"),
            ("Redshift", "dev"),
            ("CockroachDB", "defaultdb"),
        ]
        for (typeId, database) in defaults {
            guard let names = systemDatabaseNames(forTypeId: typeId) else {
                Issue.record("Registry default for \(typeId) missing")
                continue
            }
            #expect(
                !names.contains(database),
                "\(typeId) marks its default database \(database) as system, which hides it from every database list"
            )
        }
    }
}
