//
//  SOCKSProxyModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("SOCKS proxy model")
struct SOCKSProxyModelTests {
    @Test("SOCKSProxyConfiguration round-trips through Codable")
    func configurationRoundTrip() throws {
        let config = SOCKSProxyConfiguration(host: "proxy.example.com", port: 9_150, username: "tester")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SOCKSProxyConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test("SOCKSProxyConfiguration decodes missing fields to defaults")
    func configurationDecodesDefaults() throws {
        let decoded = try JSONDecoder().decode(SOCKSProxyConfiguration.self, from: Data("{}".utf8))
        #expect(decoded.host.isEmpty)
        #expect(decoded.port == 1_080)
        #expect(decoded.username.isEmpty)
    }

    @Test("SOCKSProxyMode encodes inline config and decodes back")
    func modeRoundTrip() throws {
        let mode = SOCKSProxyMode.inline(SOCKSProxyConfiguration(host: "proxy.example.com"))
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(SOCKSProxyMode.self, from: data)
        #expect(decoded == mode)
    }

    @Test("SOCKSProxyMode disabled round-trips")
    func disabledRoundTrip() throws {
        let data = try JSONEncoder().encode(SOCKSProxyMode.disabled)
        let decoded = try JSONDecoder().decode(SOCKSProxyMode.self, from: data)
        #expect(decoded == .disabled)
    }

    @Test("DatabaseConnection preserves socksProxyMode through Codable")
    func connectionRoundTrip() throws {
        let connection = DatabaseConnection(
            name: "Proxied",
            host: "db.internal.example",
            port: 5_432,
            type: .postgresql,
            socksProxyMode: .inline(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1_080, username: "u"))
        )

        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(decoded.socksProxyMode == connection.socksProxyMode)
        #expect(decoded.isSOCKSProxyEnabled)
        #expect(decoded.resolvedSOCKSProxyConfig?.host == "proxy.example.com")
    }

    @Test("a disabled mode is omitted from the encoded connection")
    func disabledModeOmitted() throws {
        let connection = DatabaseConnection(name: "Plain", type: .mysql)
        let data = try JSONEncoder().encode(connection)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["socksProxyMode"] == nil)

        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.socksProxyMode == .disabled)
        #expect(!decoded.isSOCKSProxyEnabled)
        #expect(decoded.resolvedSOCKSProxyConfig == nil)
    }

    @Test("configuration validation requires a host and an in-range port")
    func configurationValidation() {
        #expect(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1_080).isValid)
        #expect(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1).isValid)
        #expect(SOCKSProxyConfiguration(host: "proxy.example.com", port: 65_535).isValid)
        #expect(!SOCKSProxyConfiguration(host: "", port: 1_080).isValid)
        #expect(!SOCKSProxyConfiguration(host: "   ", port: 1_080).isValid)
        #expect(!SOCKSProxyConfiguration(host: "proxy.example.com", port: 0).isValid)
        #expect(!SOCKSProxyConfiguration(host: "proxy.example.com", port: 65_536).isValid)
    }

    @Test("StoredConnection round-trips socksProxyMode")
    func storedConnectionRoundTrip() throws {
        let connection = DatabaseConnection(
            name: "Proxied",
            host: "db.internal.example",
            port: 5_432,
            type: .postgresql,
            socksProxyMode: .inline(SOCKSProxyConfiguration(host: "proxy.example.com", port: 1_081))
        )

        let stored = StoredConnection(from: connection)
        let data = try JSONEncoder().encode(stored)
        let decodedStored = try JSONDecoder().decode(StoredConnection.self, from: data)
        let restored = decodedStored.toConnection()

        #expect(restored.socksProxyMode == connection.socksProxyMode)
    }

    @Test("SOCKS form state builds the tunnel mode and loads it back")
    func formStateRoundTrip() {
        var state = SOCKSProxyFormState()
        state.enabled = true
        state.host = "  proxy.example.com  "
        state.port = "9150"
        state.username = "tester"

        guard case .inline(let config) = state.buildTunnelMode() else {
            Issue.record("Expected an inline mode")
            return
        }
        #expect(config.host == "proxy.example.com")
        #expect(config.port == 9_150)
        #expect(config.username == "tester")

        var reloaded = SOCKSProxyFormState()
        reloaded.load(from: DatabaseConnection(name: "P", type: .postgresql, socksProxyMode: .inline(config)))
        #expect(reloaded.enabled)
        #expect(reloaded.host == "proxy.example.com")
        #expect(reloaded.port == "9150")
        #expect(reloaded.username == "tester")

        var disabled = SOCKSProxyFormState()
        disabled.load(from: DatabaseConnection(name: "P", type: .postgresql))
        #expect(!disabled.enabled)
    }
}
