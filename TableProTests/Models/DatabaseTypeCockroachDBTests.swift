//
//  DatabaseTypeCockroachDBTests.swift
//  TableProTests
//
//  Tests for .cockroachdb properties and plugin resolution.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseType CockroachDB")
struct DatabaseTypeCockroachDBTests {
    @Test("rawValue is CockroachDB")
    func rawValue() {
        #expect(DatabaseType.cockroachdb.rawValue == "CockroachDB")
    }

    @Test("defaultPort is 26257")
    func defaultPort() {
        #expect(DatabaseType.cockroachdb.defaultPort == 26_257)
    }

    @Test("requiresAuthentication is true")
    func requiresAuthentication() {
        #expect(DatabaseType.cockroachdb.requiresAuthentication == true)
    }

    @Test("supportsForeignKeys is true")
    func supportsForeignKeys() {
        #expect(DatabaseType.cockroachdb.supportsForeignKeys == true)
    }

    @Test("supportsSchemaEditing is true")
    func supportsSchemaEditing() {
        #expect(DatabaseType.cockroachdb.supportsSchemaEditing == true)
    }

    @Test("iconName is cockroachdb-icon")
    func iconName() {
        #expect(DatabaseType.cockroachdb.iconName == "cockroachdb-icon")
    }

    @Test("pluginTypeId resolves to PostgreSQL")
    func pluginTypeIdResolvesToPostgres() {
        #expect(DatabaseType.cockroachdb.pluginTypeId == "PostgreSQL")
    }

    @Test("EXPLAIN variants use plain text, not FORMAT JSON")
    func explainVariantsAreText() {
        let variants = DatabaseType.cockroachdb.explainVariants
        #expect(!variants.isEmpty)
        #expect(variants.allSatisfy { !$0.sqlPrefix.uppercased().contains("JSON") })
    }

    @Test("Codable round-trips through rawValue")
    func codableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(DatabaseType.cockroachdb)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: encoded)
        #expect(decoded == DatabaseType.cockroachdb)
    }

    @Test("allKnownTypes contains cockroachdb")
    func allKnownTypesContainsCockroachDB() {
        #expect(DatabaseType.allKnownTypes.contains(.cockroachdb))
    }

    @Test("allCases shim contains cockroachdb")
    func allCasesContainsCockroachDB() {
        #expect(DatabaseType.allCases.contains(.cockroachdb))
    }
}
