//
//  CloudflareModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Cloudflare tunnel model")
struct CloudflareModelTests {
    @Test("CloudflareConfiguration round-trips through Codable")
    func configurationRoundTrip() throws {
        let config = CloudflareConfiguration(
            accessHostname: "db.example.com",
            localPort: 6543,
            authMethod: .serviceToken,
            exposeToLAN: true,
            binaryPath: "/opt/homebrew/bin/cloudflared"
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CloudflareConfiguration.self, from: data)

        #expect(decoded == config)
    }

    @Test("CloudflareTunnelMode encodes inline config and decodes back")
    func tunnelModeRoundTrip() throws {
        let mode = CloudflareTunnelMode.inline(CloudflareConfiguration(accessHostname: "tcp.example.com"))

        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(CloudflareTunnelMode.self, from: data)

        #expect(decoded == mode)
    }

    @Test("CloudflareTunnelMode disabled round-trips")
    func disabledRoundTrip() throws {
        let data = try JSONEncoder().encode(CloudflareTunnelMode.disabled)
        let decoded = try JSONDecoder().decode(CloudflareTunnelMode.self, from: data)
        #expect(decoded == .disabled)
    }

    @Test("DatabaseConnection preserves cloudflareTunnelMode through Codable")
    func connectionRoundTrip() throws {
        let connection = DatabaseConnection(
            name: "CF",
            host: "db.internal",
            port: 5432,
            type: .postgresql,
            cloudflareTunnelMode: .inline(CloudflareConfiguration(accessHostname: "db.example.com", authMethod: .browserSSO))
        )

        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(decoded.cloudflareTunnelMode == connection.cloudflareTunnelMode)
        #expect(decoded.isCloudflareEnabled)
        #expect(decoded.resolvedCloudflareConfig?.accessHostname == "db.example.com")
    }

    @Test("DatabaseConnection without cloudflare defaults to disabled")
    func connectionDefaultsDisabled() throws {
        let connection = DatabaseConnection(name: "Plain", type: .mysql)
        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(decoded.cloudflareTunnelMode == .disabled)
        #expect(!decoded.isCloudflareEnabled)
        #expect(decoded.resolvedCloudflareConfig == nil)
    }

    @Test("CloudflaredPidRecord round-trips for the stale-PID sweep")
    func pidRecordRoundTrip() throws {
        let records = [CloudflaredPidRecord(pid: 4242, binaryPath: "/opt/homebrew/bin/cloudflared")]
        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([CloudflaredPidRecord].self, from: data)
        #expect(decoded == records)
    }
}
