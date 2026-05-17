//
//  DatabaseTypeTests.swift
//  TableProTests
//
//  Tests for DatabaseType enum
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("DatabaseType")
struct DatabaseTypeTests {

    @Test("MySQL default port is 3306")
    func testMySQLDefaultPort() {
        #expect(DatabaseType.mysql.defaultPort == 3306)
    }

    @Test("MariaDB default port is 3306")
    func testMariaDBDefaultPort() {
        #expect(DatabaseType.mariadb.defaultPort == 3306)
    }

    @Test("PostgreSQL default port is 5432")
    func testPostgreSQLDefaultPort() {
        #expect(DatabaseType.postgresql.defaultPort == 5432)
    }

    @Test("SQLite default port is 0")
    func testSQLiteDefaultPort() {
        #expect(DatabaseType.sqlite.defaultPort == 0)
    }

    @Test("MongoDB default port is 27017")
    func testMongoDBDefaultPort() {
        #expect(DatabaseType.mongodb.defaultPort == 27_017)
    }

    @Test("allKnownTypes contains all built-in types")
    func testAllKnownTypesContainsBuiltIns() {
        let knownTypes = DatabaseType.allKnownTypes
        #expect(knownTypes.contains(.mysql))
        #expect(knownTypes.contains(.postgresql))
        #expect(knownTypes.contains(.sqlite))
        #expect(knownTypes.count >= 5)
    }

    @Test("allCases shim matches allKnownTypes")
    func testAllCasesShim() {
        #expect(DatabaseType.allCases == DatabaseType.allKnownTypes)
    }

    @Test("Raw value matches display name", arguments: [
        (DatabaseType.mysql, "MySQL"),
        (DatabaseType.mariadb, "MariaDB"),
        (DatabaseType.postgresql, "PostgreSQL"),
        (DatabaseType.sqlite, "SQLite"),
        (DatabaseType.mongodb, "MongoDB"),
        (DatabaseType.redis, "Redis"),
        (DatabaseType.redshift, "Redshift"),
        (DatabaseType.mssql, "SQL Server"),
        (DatabaseType.oracle, "Oracle"),
        (DatabaseType.clickhouse, "ClickHouse"),
        (DatabaseType.duckdb, "DuckDB"),
        (DatabaseType.cassandra, "Cassandra"),
        (DatabaseType.scylladb, "ScyllaDB")
    ])
    func testRawValueMatchesDisplayName(dbType: DatabaseType, expectedRawValue: String) {
        #expect(dbType.rawValue == expectedRawValue)
    }

    // MARK: - ClickHouse Tests

    @Test("ClickHouse default port is 8123")
    func testClickHouseDefaultPort() {
        #expect(DatabaseType.clickhouse.defaultPort == 8_123)
    }

    @Test("ClickHouse requires authentication")
    func testClickHouseRequiresAuth() {
        #expect(DatabaseType.clickhouse.requiresAuthentication == true)
    }

    @Test("ClickHouse does not support foreign keys")
    func testClickHouseSupportsForeignKeys() {
        #expect(DatabaseType.clickhouse.supportsForeignKeys == false)
    }

    @Test("ClickHouse supports schema editing")
    func testClickHouseSupportsSchemaEditing() {
        #expect(DatabaseType.clickhouse.supportsSchemaEditing == true)
    }

    @Test("ClickHouse icon name is clickhouse-icon")
    func testClickHouseIconName() {
        #expect(DatabaseType.clickhouse.iconName == "clickhouse-icon")
    }

    // MARK: - Plugin Type ID Alias Tests

    @Test("MariaDB pluginTypeId maps to MySQL plugin")
    func testMariaDBPluginTypeId() {
        #expect(DatabaseType.mariadb.pluginTypeId == "MySQL")
    }

    @Test("Redshift pluginTypeId maps to PostgreSQL plugin")
    func testRedshiftPluginTypeId() {
        #expect(DatabaseType.redshift.pluginTypeId == "PostgreSQL")
    }

    @Test("Unknown type pluginTypeId falls back to rawValue")
    func testUnknownPluginTypeIdFallback() {
        #expect(DatabaseType(rawValue: "FutureDB").pluginTypeId == "FutureDB")
    }

    // MARK: - Struct Behavior Tests

    @Test("Struct equality via rawValue")
    func testStructEquality() {
        #expect(DatabaseType(rawValue: "MySQL") == .mysql)
    }

    // MARK: - Default SSL Mode Tests

    @Test("libpq-family engines default SSL mode to preferred", arguments: [
        DatabaseType.postgresql,
        DatabaseType.redshift,
        DatabaseType.cockroachdb
    ])
    func testLibPQEnginesDefaultSSLPreferred(type: DatabaseType) {
        #expect(type.defaultSSLMode == .preferred)
    }

    @Test("SQL Server defaults SSL mode to preferred")
    func testMSSQLDefaultSSLPreferred() {
        #expect(DatabaseType.mssql.defaultSSLMode == .preferred)
    }

    @Test("libmariadb-family engines default SSL mode to preferred (2-pass connect)", arguments: [
        DatabaseType.mysql,
        DatabaseType.mariadb
    ])
    func testMariaDBClientEnginesDefaultSSLPreferred(type: DatabaseType) {
        #expect(type.defaultSSLMode == .preferred)
    }

    @Test("Binary on/off engines default SSL mode to disabled", arguments: [
        DatabaseType.mongodb,
        DatabaseType.redis,
        DatabaseType.cassandra,
        DatabaseType.clickhouse,
        DatabaseType.oracle
    ])
    func testBinaryEnginesDefaultSSLDisabled(type: DatabaseType) {
        #expect(type.defaultSSLMode == .disabled)
    }

    @Test("Local file-based engines default SSL mode to disabled", arguments: [
        DatabaseType.sqlite,
        DatabaseType.duckdb
    ])
    func testLocalEnginesDefaultSSLDisabled(type: DatabaseType) {
        #expect(type.defaultSSLMode == .disabled)
    }

    @Test("Unknown future engine defaults SSL mode to disabled")
    func testUnknownEngineDefaultSSLDisabled() {
        #expect(DatabaseType(rawValue: "FutureDB").defaultSSLMode == .disabled)
    }

    @Test("Drivers with native prefer support report supportsOpportunisticTLS=true", arguments: [
        DatabaseType.postgresql,
        DatabaseType.redshift,
        DatabaseType.cockroachdb,
        DatabaseType.mysql,
        DatabaseType.mariadb,
        DatabaseType.mssql
    ])
    func testOpportunisticTLSSupported(type: DatabaseType) {
        #expect(type.supportsOpportunisticTLS == true)
    }

    @Test("Binary-TLS drivers report supportsOpportunisticTLS=false", arguments: [
        DatabaseType.mongodb,
        DatabaseType.redis,
        DatabaseType.cassandra,
        DatabaseType.scylladb,
        DatabaseType.clickhouse,
        DatabaseType.oracle,
        DatabaseType.etcd
    ])
    func testOpportunisticTLSUnsupported(type: DatabaseType) {
        #expect(type.supportsOpportunisticTLS == false)
    }

    @Test("Unknown type round-trips via rawValue")
    func testUnknownTypeRoundTrip() {
        #expect(DatabaseType(rawValue: "FutureDB").rawValue == "FutureDB")
    }

    @Test("Validating init rejects unknown type")
    func testValidatingInitRejectsUnknown() {
        #expect(DatabaseType(validating: "FutureDB") == nil)
    }

    @Test("Validating init accepts known type")
    func testValidatingInitAcceptsKnown() {
        #expect(DatabaseType(validating: "MySQL") == .mysql)
    }

    @Test("Codable round-trip for known type")
    func testCodableRoundTrip() throws {
        let original = DatabaseType.postgresql
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable round-trip for unknown type")
    func testCodableUnknownRoundTrip() throws {
        let original = DatabaseType(rawValue: "FutureDB")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: data)
        #expect(decoded == original)
        #expect(decoded.rawValue == "FutureDB")
    }

    @Test("Hashable set membership works")
    func testHashableSetMembership() {
        let types: Set<DatabaseType> = [.mysql, .postgresql, .sqlite]
        #expect(types.contains(.mysql))
        #expect(types.contains(.postgresql))
        #expect(!types.contains(.redis))
    }
}
