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

struct DatabaseTypeTests {

    // MARK: - Plugin Type ID Alias Tests

    @Test("Unknown type pluginTypeId falls back to rawValue")
    func testUnknownPluginTypeIdFallback() {
        #expect(DatabaseType(rawValue: "FutureDB").pluginTypeId == "FutureDB")
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
        DatabaseType.mariadb,
        DatabaseType.tidb,
        DatabaseType.databend,
        DatabaseType.oceanbase
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
        DatabaseType.tidb,
        DatabaseType.databend,
        DatabaseType.oceanbase,
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
        DatabaseType.etcd,
        DatabaseType.trino
    ])
    func testOpportunisticTLSUnsupported(type: DatabaseType) {
        #expect(type.supportsOpportunisticTLS == false)
    }

    @Test("Trino and ClickHouse imply Verify Identity on the ports their own clients treat as TLS")
    func testTLSImpliedPorts() {
        #expect(DatabaseType.trino.impliedSSLMode(forPort: 443) == .verifyIdentity)
        #expect(DatabaseType.trino.impliedSSLMode(forPort: 8_443) == nil)
        #expect(DatabaseType.trino.impliedSSLMode(forPort: 8_080) == nil)
        #expect(DatabaseType.clickhouse.impliedSSLMode(forPort: 443) == .verifyIdentity)
        #expect(DatabaseType.clickhouse.impliedSSLMode(forPort: 8_443) == .verifyIdentity)
        #expect(DatabaseType.clickhouse.impliedSSLMode(forPort: 8_123) == nil)
        #expect(DatabaseType.postgresql.impliedSSLMode(forPort: 443) == nil)
        #expect(DatabaseType(rawValue: "FutureDB").impliedSSLMode(forPort: 443) == nil)
    }

    @Test("An omitted port is the driver's TLS port once TLS is on, where it has one")
    func testPortWhenOmitted() {
        #expect(DatabaseType.clickhouse.portWhenOmitted(tlsEnabled: true) == 8_443)
        #expect(DatabaseType.clickhouse.portWhenOmitted(tlsEnabled: false) == 8_123)
        #expect(DatabaseType.trino.portWhenOmitted(tlsEnabled: true) == 443)
        #expect(DatabaseType.trino.portWhenOmitted(tlsEnabled: false) == 8_080)
        #expect(DatabaseType.postgresql.portWhenOmitted(tlsEnabled: true) == 5_432)
    }

    @Test("TLS turned on without a named check verifies the host only where no CA file is needed")
    func testSSLModeWhenTLSEnabled() {
        #expect(DatabaseType.trino.sslModeWhenTLSEnabled == .verifyIdentity)
        #expect(DatabaseType.clickhouse.sslModeWhenTLSEnabled == .verifyIdentity)
        #expect(DatabaseType.postgresql.sslModeWhenTLSEnabled == .required)
        #expect(DatabaseType.mongodb.sslModeWhenTLSEnabled == .required)
        #expect(DatabaseType(rawValue: "FutureDB").sslModeWhenTLSEnabled == .required)
    }

    @Test("The SSL mode a port resolves to carries whether the port or the driver default chose it")
    func testSSLModeResolutionForPort() {
        #expect(DatabaseType.postgresql.sslModeResolution(forPort: 5_432)
            == SSLModeResolution(mode: .preferred, origin: .typeDefault))
        #expect(DatabaseType.trino.sslModeResolution(forPort: 443)
            == SSLModeResolution(mode: .verifyIdentity, origin: .impliedByPort))
        #expect(DatabaseType.clickhouse.sslModeResolution(forPort: 8_123)
            == SSLModeResolution(mode: .disabled, origin: .typeDefault))
    }

    @Test("Verify Identity skips the CA file only where the driver checks the system trust store")
    func testCACertificateRequirement() {
        #expect(DatabaseType.trino.requiresCACertificate(for: .verifyIdentity) == false)
        #expect(DatabaseType.clickhouse.requiresCACertificate(for: .verifyIdentity) == false)
        #expect(DatabaseType.postgresql.requiresCACertificate(for: .verifyIdentity) == true)
        #expect(DatabaseType.mysql.requiresCACertificate(for: .verifyIdentity) == true)
        #expect(DatabaseType(rawValue: "FutureDB").requiresCACertificate(for: .verifyIdentity) == true)
    }

    @Test("Verify CA checks no hostname, so it always needs a CA file where the form shows one")
    func testVerifyCAAlwaysRequiresTheCAFile() {
        #expect(DatabaseType.trino.requiresCACertificate(for: .verifyCa) == true)
        #expect(DatabaseType.clickhouse.requiresCACertificate(for: .verifyCa) == true)
        #expect(DatabaseType.postgresql.requiresCACertificate(for: .verifyCa) == true)
        #expect(DatabaseType.mssql.supportsPerConnectionCertificatePaths == false)
        #expect(DatabaseType.mssql.requiresCACertificate(for: .verifyCa) == false)
        #expect(DatabaseType.mssql.requiresCACertificate(for: .verifyIdentity) == false)
        #expect(DatabaseType.trino.requiresCACertificate(for: .required) == false)
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

    @Test("Codable round-trip for unknown type")
    func testCodableUnknownRoundTrip() throws {
        let original = DatabaseType(rawValue: "FutureDB")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseType.self, from: data)
        #expect(decoded == original)
        #expect(decoded.rawValue == "FutureDB")
    }
}
