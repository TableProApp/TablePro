//
//  MCPServerStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private var values: [String: String] = [:]

    var storedKeys: Set<String> { Set(values.keys) }

    func writeString(_ value: String, forKey key: String) -> Bool {
        values[key] = value
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        values[key].map { .found($0) } ?? .notFound
    }

    func delete(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

private final class LockedKeychain: KeychainStoring, @unchecked Sendable {
    func writeString(_ value: String, forKey key: String) -> Bool { false }
    func readStringResult(forKey key: String) -> KeychainStringResult { .locked }
    func delete(forKey key: String) {}
}

@MainActor
struct MCPServerStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MCPServerStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return .standard }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func endpoint(_ string: String = "https://runbooks.example/mcp") -> URL {
        guard let url = URL(string: string) else { return URL(fileURLWithPath: "/") }
        return url
    }

    @Test("A refused configuration is not stored")
    func invalidConfigurationIsNotStored() {
        let store = MCPServerStore(defaults: makeDefaults(), keychain: FakeKeychain())
        let error = store.upsert(
            MCPServerConfiguration(name: "Runbooks", endpoint: endpoint("http://elsewhere.example/mcp")),
            token: "t"
        )

        #expect(error == .insecureEndpoint)
        #expect(store.servers.isEmpty)
    }

    @Test("A stored server survives a reload from the same defaults")
    func storedServerRoundTrips() {
        let defaults = makeDefaults()
        let keychain = FakeKeychain()
        let connectionId = UUID()
        let store = MCPServerStore(defaults: defaults, keychain: keychain)
        let configuration = MCPServerConfiguration(
            name: "Runbooks",
            endpoint: endpoint(),
            allowedConnectionIds: [connectionId]
        )
        #expect(store.upsert(configuration, token: "secret") == nil)

        let reloaded = MCPServerStore(defaults: defaults, keychain: keychain)

        #expect(reloaded.servers.count == 1)
        #expect(reloaded.server(id: configuration.id)?.name == "Runbooks")
        #expect(reloaded.token(for: configuration.id) == "secret")
        #expect(reloaded.servers(allowedFor: connectionId).count == 1)
    }

    /// A token left behind would be a live secret for a server the user believes they deleted.
    @Test("Removing a server removes its token with it")
    func removingTakesTheTokenWithIt() {
        let keychain = FakeKeychain()
        let store = MCPServerStore(defaults: makeDefaults(), keychain: keychain)
        let configuration = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint())
        #expect(store.upsert(configuration, token: "secret") == nil)
        #expect(!keychain.storedKeys.isEmpty)

        store.remove(id: configuration.id)

        #expect(store.servers.isEmpty)
        #expect(keychain.storedKeys.isEmpty)
    }

    /// A token TablePro cannot read is a token it does not have, and the call that needs it fails
    /// with the server unreachable rather than going out unauthenticated.
    @Test("A locked Keychain reads as no token")
    func lockedKeychainReadsAsNoToken() {
        let store = MCPServerStore(defaults: makeDefaults(), keychain: LockedKeychain())
        let configuration = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint())
        _ = store.upsert(configuration, token: "secret")

        #expect(store.token(for: configuration.id) == nil)
    }

    @Test("A session with no connection is allowed no server")
    func nilConnectionIsAllowedNothing() {
        let store = MCPServerStore(defaults: makeDefaults(), keychain: FakeKeychain())
        let connectionId = UUID()
        let configuration = MCPServerConfiguration(
            name: "Runbooks",
            endpoint: endpoint(),
            allowedConnectionIds: [connectionId]
        )
        _ = store.upsert(configuration, token: "secret")

        #expect(store.servers(allowedFor: nil).isEmpty)
        #expect(store.servers(allowedFor: UUID()).isEmpty)
        #expect(store.servers(allowedFor: connectionId).count == 1)
    }

    @Test("A namespaced tool resolves to its own server and only from an allowed connection")
    func toolOwnershipFollowsTheAllowlist() {
        let store = MCPServerStore(defaults: makeDefaults(), keychain: FakeKeychain())
        let connectionId = UUID()
        let configuration = MCPServerConfiguration(
            name: "Runbooks",
            endpoint: endpoint(),
            allowedConnectionIds: [connectionId]
        )
        _ = store.upsert(configuration, token: "secret")
        let toolName = configuration.toolName(for: "search")

        #expect(store.server(owningTool: toolName)?.id == configuration.id)
        #expect(store.allowsTool(named: toolName, connectionId: connectionId))
        #expect(!store.allowsTool(named: toolName, connectionId: UUID()))
        #expect(!store.allowsTool(named: "execute_query", connectionId: connectionId))
    }

    @Test("Setting and clearing a connection moves the allowlist")
    func settingAllowedMovesTheList() {
        let store = MCPServerStore(defaults: makeDefaults(), keychain: FakeKeychain())
        let connectionId = UUID()
        let configuration = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint())
        _ = store.upsert(configuration, token: "secret")

        store.setAllowed(true, serverId: configuration.id, connectionId: connectionId)
        #expect(store.server(id: configuration.id)?.allows(connectionId: connectionId) == true)

        store.setAllowed(false, serverId: configuration.id, connectionId: connectionId)
        #expect(store.server(id: configuration.id)?.allows(connectionId: connectionId) == false)
    }

    /// A deleted connection's id must not sit in an allowlist forever. A new connection cannot
    /// inherit it, but a stale entry makes the settings pane lie about how far a server reaches.
    @Test("Forgetting a connection takes it off every allowlist")
    func forgettingAConnectionClearsIt() {
        let defaults = makeDefaults()
        let keychain = FakeKeychain()
        let store = MCPServerStore(defaults: defaults, keychain: keychain)
        let connectionId = UUID()
        let first = MCPServerConfiguration(
            name: "Runbooks",
            endpoint: endpoint(),
            allowedConnectionIds: [connectionId]
        )
        let second = MCPServerConfiguration(
            name: "Tickets",
            endpoint: endpoint("https://tickets.example/mcp"),
            allowedConnectionIds: [connectionId, UUID()]
        )
        _ = store.upsert(first, token: "a")
        _ = store.upsert(second, token: "b")

        store.forgetConnection(connectionId)

        #expect(store.servers.allSatisfy { !$0.allows(connectionId: connectionId) })
        #expect(MCPServerStore(defaults: defaults, keychain: keychain).servers(allowedFor: connectionId).isEmpty)
    }

    @Test("Editing a server keeps the token it already had")
    func editingKeepsTheStoredToken() {
        let store = MCPServerStore(defaults: makeDefaults(), keychain: FakeKeychain())
        var configuration = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint())
        _ = store.upsert(configuration, token: "secret")

        configuration.name = "Runbooks (staging)"
        #expect(store.upsert(configuration, token: nil) == nil)

        #expect(store.server(id: configuration.id)?.name == "Runbooks (staging)")
        #expect(store.token(for: configuration.id) == "secret")
    }
}
