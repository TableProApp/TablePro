//
//  CloudSQLProxyModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Cloud SQL Auth Proxy model")
struct CloudSQLProxyModelTests {
    @Test("CloudSQLProxyConfiguration round-trips through Codable")
    func configurationRoundTrip() throws {
        let config = CloudSQLProxyConfiguration(
            instanceConnectionName: "my-project:us-central1:main",
            authMode: .serviceAccountKey,
            useIAMAuth: true,
            usePrivateIP: true,
            localPort: 6543,
            binaryPath: "/opt/homebrew/bin/cloud-sql-proxy"
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CloudSQLProxyConfiguration.self, from: data)

        #expect(decoded == config)
    }

    @Test("CloudSQLProxyMode encodes inline config and decodes back")
    func modeRoundTrip() throws {
        let mode = CloudSQLProxyMode.inline(
            CloudSQLProxyConfiguration(instanceConnectionName: "p:r:i")
        )

        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(CloudSQLProxyMode.self, from: data)

        #expect(decoded == mode)
    }

    @Test("CloudSQLProxyMode disabled round-trips")
    func disabledRoundTrip() throws {
        let data = try JSONEncoder().encode(CloudSQLProxyMode.disabled)
        let decoded = try JSONDecoder().decode(CloudSQLProxyMode.self, from: data)
        #expect(decoded == .disabled)
    }

    @Test("DatabaseConnection preserves cloudSQLProxyMode through Codable")
    func connectionRoundTrip() throws {
        let connection = DatabaseConnection(
            name: "Cloud SQL",
            host: "ignored",
            port: 5432,
            type: .postgresql,
            cloudSQLProxyMode: .inline(
                CloudSQLProxyConfiguration(instanceConnectionName: "proj:region:inst", authMode: .applicationDefault)
            )
        )

        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(decoded.cloudSQLProxyMode == connection.cloudSQLProxyMode)
        #expect(decoded.isCloudSQLProxyEnabled)
        #expect(decoded.resolvedCloudSQLProxyConfig?.instanceConnectionName == "proj:region:inst")
    }

    @Test("DatabaseConnection without Cloud SQL Proxy defaults to disabled")
    func connectionDefaultsDisabled() throws {
        let connection = DatabaseConnection(name: "Plain", type: .mysql)
        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(decoded.cloudSQLProxyMode == .disabled)
        #expect(!decoded.isCloudSQLProxyEnabled)
        #expect(decoded.resolvedCloudSQLProxyConfig == nil)
    }

    @Test("Instance connection name validation")
    func instanceConnectionNameValidation() {
        func isValid(_ name: String) -> Bool {
            CloudSQLProxyConfiguration(instanceConnectionName: name).isValid
        }

        #expect(isValid("project:region:instance"))
        #expect(isValid("example.com:project:region:instance"))
        #expect(!isValid("project"))
        #expect(!isValid("project:region"))
        #expect(!isValid("project::instance"))
        #expect(!isValid("project:region:"))
        #expect(!isValid(""))
    }

    @Test("CloudSQLProxyPidRecord round-trips for the stale-PID sweep")
    func pidRecordRoundTrip() throws {
        let records = [CloudSQLProxyPidRecord(pid: 4242, binaryPath: "/opt/homebrew/bin/cloud-sql-proxy")]
        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([CloudSQLProxyPidRecord].self, from: data)
        #expect(decoded == records)
    }

    @Test("supportsCloudSQLProxy is limited to Cloud SQL engines")
    func capabilityEngines() {
        #expect(DatabaseType.mysql.supportsCloudSQLProxy)
        #expect(DatabaseType.postgresql.supportsCloudSQLProxy)
        #expect(DatabaseType.mssql.supportsCloudSQLProxy)
        #expect(!DatabaseType.mariadb.supportsCloudSQLProxy)
        #expect(!DatabaseType.sqlite.supportsCloudSQLProxy)
        #expect(!DatabaseType.mongodb.supportsCloudSQLProxy)
    }
}
