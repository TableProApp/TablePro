//
//  SOCKSProxyModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

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

    @Test("The editor's SOCKS draft writes the tunnel mode trimmed and loads it back")
    @MainActor
    func draftRoundTrip() {
        let postgres = ConnectionTypeTraits.live(for: .postgresql, pluginManager: .shared)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.selectTransport(.socksProxy)
        draft.socksProxy.host = "  proxy.example.com  "
        draft.socksProxy.port = "9150"
        draft.socksProxy.username = "tester"

        let edits = ConnectionEditorEngine.edits(draft, postgres, originalTraits: nil, EditorContext())
        guard case .inline(let config) = edits.socksProxyMode else {
            Issue.record("Expected an inline mode")
            return
        }
        #expect(config.host == "proxy.example.com")
        #expect(config.port == 9_150)
        #expect(config.username == "tester")

        let reloaded = ConnectionDraft.loaded(
            from: DatabaseConnection(name: "P", type: .postgresql, socksProxyMode: .inline(config)),
            secrets: .none,
            traits: postgres
        )
        #expect(reloaded.transport == .socksProxy)
        #expect(reloaded.socksProxy.host == "proxy.example.com")
        #expect(reloaded.socksProxy.port == "9150")
        #expect(reloaded.socksProxy.username == "tester")

        let disabled = ConnectionDraft.loaded(from: DatabaseConnection(name: "P", type: .postgresql), secrets: .none, traits: postgres)
        #expect(disabled.transport == nil)
        #expect(ConnectionEditorEngine.edits(disabled, postgres, originalTraits: nil, EditorContext()).socksProxyMode == .disabled)
    }
}
