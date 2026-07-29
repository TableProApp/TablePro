//
//  DatabaseTypePGliteTests.swift
//  TableProTests
//
//  Tests for .pglite properties and plugin resolution.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseType PGlite")
struct DatabaseTypePGliteTests {
    @Test("rawValue is PGlite")
    func rawValue() {
        #expect(DatabaseType.pglite.rawValue == "PGlite")
    }

    @Test("defaultPort is 5432")
    func defaultPort() {
        #expect(DatabaseType.pglite.defaultPort == 5_432)
    }

    @Test("defaultHost is loopback IPv4")
    func defaultHost() {
        #expect(DatabaseType.pglite.defaultHost == "127.0.0.1")
    }

    @Test("SSL is disabled by default (socket server has no TLS)")
    func defaultSSLModeDisabled() {
        #expect(DatabaseType.pglite.defaultSSLMode == .disabled)
    }

    @Test("connection pooling is off (single connection)")
    func doesNotPool() {
        #expect(DatabaseType.pglite.supportsConnectionPooling == false)
    }

    @Test("PostgreSQL still pools (default unchanged)")
    func postgresStillPools() {
        #expect(DatabaseType.postgresql.supportsConnectionPooling == true)
    }

    @Test("iconName reuses the PostgreSQL icon")
    func iconName() {
        #expect(DatabaseType.pglite.iconName == "postgresql-icon")
    }

    @Test("pluginTypeId resolves to PostgreSQL")
    func pluginTypeIdResolvesToPostgres() {
        #expect(DatabaseType.pglite.pluginTypeId == "PostgreSQL")
    }

    @Test("Codable round-trips through rawValue")
    func codableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(DatabaseType.pglite)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: encoded)
        #expect(decoded == DatabaseType.pglite)
    }

    @Test("allKnownTypes contains pglite")
    func allKnownTypesContainsPGlite() {
        #expect(DatabaseType.allKnownTypes.contains(.pglite))
    }
}
