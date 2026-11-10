//
//  MCPTokenStoreRecoveryTests.swift
//  TableProTests
//

import Foundation
import TableProMCP
import Testing

@testable import TablePro

private final class ScriptedCredentialStore: MCPTokenCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var readable = true
    private var writes = 0

    init(stored: Data?) {
        self.stored = stored
    }

    func setReadable(_ value: Bool) {
        lock.withLock { readable = value }
    }

    var writeCount: Int {
        lock.withLock { writes }
    }

    var storedData: Data? {
        lock.withLock { stored }
    }

    func read() -> MCPTokenBlob {
        lock.withLock {
            guard readable else { return .unreadable }
            return stored.map(MCPTokenBlob.found) ?? .missing
        }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.withLock {
            stored = data
            writes += 1
        }
        return true
    }

    func delete() {
        lock.withLock { stored = nil }
    }
}

struct MCPTokenStoreRecoveryTests {
    private func makeToken(name: String) -> MCPAuthToken {
        MCPAuthToken(
            id: UUID(),
            name: name,
            prefix: "tp_abc12",
            tokenHash: "fakehash-\(name)",
            salt: "fakesalt",
            permissions: .readOnly,
            connectionAccess: .all,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: nil,
            expiresAt: nil,
            isActive: true
        )
    }

    private func blob(_ tokens: [MCPAuthToken], extra: [[String: Any]] = []) throws -> Data {
        let encoded = try MCPTokenStore.encodeStored(tokens: tokens, undecoded: [])
        var entries = try #require(try JSONSerialization.jsonObject(with: encoded) as? [Any])
        entries.append(contentsOf: extra)
        return try JSONSerialization.data(withJSONObject: entries)
    }

    private func futureEntry(name: String = "from-a-newer-build") -> [String: Any] {
        [
            "id": UUID().uuidString,
            "name": name,
            "tokenHash": "hash",
            "salt": "salt",
            "permissions": "somethingNewer",
            "createdAt": "2026-01-01T00:00:00Z",
            "isActive": true
        ]
    }

    private func storedNames(_ store: ScriptedCredentialStore) throws -> [String] {
        let data = try #require(store.storedData)
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return entries.compactMap { $0["name"] as? String }
    }

    private func mint(_ store: MCPTokenStore, name: String, bridge: Bool = false) async throws -> String {
        try await store.generate(
            name: name,
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: bridge,
            extraScopes: []
        ).plaintext
    }

    @Test("One entry this build cannot decode leaves the other tokens loaded")
    func undecodableEntryKeepsTheRest() async throws {
        let paired = makeToken(name: "paired")
        let credentials = ScriptedCredentialStore(stored: try blob([paired], extra: [futureEntry()]))
        let store = MCPTokenStore(credentialStore: credentials)

        await store.loadFromDisk()

        #expect(await store.list().map(\.id) == [paired.id])
    }

    @Test("Saving writes the undecodable entry back beside the others")
    func undecodableEntrySurvivesASave() async throws {
        let paired = makeToken(name: "paired")
        let credentials = ScriptedCredentialStore(stored: try blob([paired], extra: [futureEntry()]))
        let store = MCPTokenStore(credentialStore: credentials)
        await store.loadFromDisk()

        _ = try await mint(store, name: "bridge", bridge: true)

        let names = try storedNames(credentials)
        #expect(names.contains("paired"))
        #expect(names.contains("from-a-newer-build"))
        #expect(names.contains("bridge"))
    }

    @Test("A failed read does not let the bridge mint overwrite the stored tokens")
    func unreadableStoreIsNotOverwritten() async throws {
        let paired = makeToken(name: "paired")
        let original = try blob([paired])
        let credentials = ScriptedCredentialStore(stored: original)
        credentials.setReadable(false)
        let store = MCPTokenStore(credentialStore: credentials)
        await store.loadFromDisk()

        let plaintext = try await mint(store, name: "bridge", bridge: true)

        #expect(credentials.writeCount == 0)
        #expect(credentials.storedData == original)
        #expect(await store.validate(bearerToken: plaintext) != nil)
    }

    @Test("Once the read works again the stored tokens and the ones minted meanwhile are both kept")
    func recoveryMergesBothSides() async throws {
        let paired = makeToken(name: "paired")
        let credentials = ScriptedCredentialStore(stored: try blob([paired]))
        credentials.setReadable(false)
        let store = MCPTokenStore(credentialStore: credentials)
        await store.loadFromDisk()
        _ = try await mint(store, name: "minted-while-unreadable", bridge: true)

        credentials.setReadable(true)
        _ = try await mint(store, name: "minted-after")

        let names = Set(await store.list().map(\.name))
        #expect(names == ["paired", "minted-while-unreadable", "minted-after"])
        #expect(Set(try storedNames(credentials)) == names)
    }

    @Test("Minting a client token while the stored list is unreadable fails and keeps nothing")
    func mintFailsWhileUnreadable() async throws {
        let credentials = ScriptedCredentialStore(stored: try blob([makeToken(name: "paired")]))
        credentials.setReadable(false)
        let store = MCPTokenStore(credentialStore: credentials)
        await store.loadFromDisk()

        await #expect(throws: MCPTokenStoreError.storedTokensUnreadable) {
            _ = try await mint(store, name: "new-client")
        }

        #expect(await store.list().isEmpty)
        #expect(credentials.writeCount == 0)
    }

    @Test("A request from a paired client retries the read")
    func authenticationRetriesTheRead() async throws {
        let paired = makeToken(name: "paired")
        let credentials = ScriptedCredentialStore(stored: try blob([paired]))
        credentials.setReadable(false)
        let store = MCPTokenStore(credentialStore: credentials)
        await store.loadFromDisk()
        #expect(await store.list().isEmpty)

        credentials.setReadable(true)
        _ = await store.validate(bearerToken: "tp_unknown")

        #expect(await store.list().map(\.id) == [paired.id])
    }

    @Test("A bridge token left in the store is dropped when the read recovers")
    func recoveryDropsStaleBridgeTokens() async throws {
        let stale = MCPAuthToken(
            id: UUID(),
            name: MCPTokenStore.stdioBridgeTokenName,
            prefix: "tp_old",
            tokenHash: "old",
            salt: "salt",
            permissions: .readWrite,
            connectionAccess: .all,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: nil,
            expiresAt: nil,
            isActive: true,
            isBridgeCredential: true
        )
        let credentials = ScriptedCredentialStore(stored: try blob([stale, makeToken(name: "paired")]))
        credentials.setReadable(false)
        let store = MCPTokenStore(credentialStore: credentials)
        await store.loadFromDisk()
        let current = try await store.generate(
            name: MCPTokenStore.stdioBridgeTokenName,
            permissions: .readWrite,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: true,
            extraScopes: []
        ).token

        credentials.setReadable(true)
        _ = await store.validate(bearerToken: "tp_unknown")

        let ids = Set(await store.list().map(\.id))
        #expect(ids.contains(current.id))
        #expect(!ids.contains(stale.id))
        #expect(ids.count == 2)
    }
}
