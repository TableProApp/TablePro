//
//  MCPTokenStoreTests.swift
//  TableProTests
//
//  Minting a token is a grant, so the store makes the caller state the grant: `generate` takes the
//  connection scope and the expiry with no defaults, because the defaults it used to carry handed
//  every caller that forgot them a token over every connection that never expired. Two tokens may
//  share a name; pairing no longer revokes an existing token because a new client claimed the same
//  one, which let any caller name an installed client and take its access away.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class InMemoryCredentialStore: MCPTokenCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    init(seed: Data? = Data("[]".utf8)) {
        self.stored = seed
    }

    func read() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stored = data
        return true
    }

    func delete() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }

    var storedText: String {
        lock.lock()
        defer { lock.unlock() }
        guard let stored else { return "" }
        return String(bytes: stored, encoding: .utf8) ?? ""
    }
}

@Suite("MCP Token Store")
struct MCPTokenStoreTests {
    private func makeStore(
        _ credentialStore: InMemoryCredentialStore = InMemoryCredentialStore()
    ) -> MCPTokenStore {
        MCPTokenStore(credentialStore: credentialStore)
    }

    private func makeToken(isActive: Bool = true, expiresAt: Date? = nil) -> MCPAuthToken {
        MCPAuthToken(
            id: UUID(),
            name: "test-token",
            prefix: "tp_abc12",
            tokenHash: "fakehash",
            salt: "fakesalt",
            permissions: .readOnly,
            connectionAccess: .all,
            createdAt: Date.now,
            lastUsedAt: nil,
            expiresAt: expiresAt,
            isActive: isActive
        )
    }

    @Test("Read only grants no write and no admin scope")
    func readOnlyScopes() {
        #expect(TokenPermissions.readOnly.scopes == MCPScope.readOnlySet)
        #expect(TokenPermissions.readOnly.scopes.contains(.toolsWrite) == false)
        #expect(TokenPermissions.readOnly.scopes.contains(.admin) == false)
    }

    @Test("Read and write grants writing but not administration")
    func readWriteScopes() {
        #expect(TokenPermissions.readWrite.scopes == MCPScope.readWriteSet)
        #expect(TokenPermissions.readWrite.scopes.contains(.toolsWrite))
        #expect(TokenPermissions.readWrite.scopes.contains(.admin) == false)
    }

    @Test("Full access is the only tier carrying the admin scope")
    func fullAccessScopes() {
        #expect(TokenPermissions.fullAccess.scopes == MCPScope.fullAccessSet)
        #expect(TokenPermissions.allCases.filter({ $0.scopes.contains(.admin) }) == [.fullAccess])
    }

    @Test("Every permission tier has a display name")
    func displayNamesAreNotEmpty() {
        for permission in TokenPermissions.allCases {
            #expect(permission.displayName.isEmpty == false)
        }
    }

    @Test("A token with no expiry never expires, one in the past already has")
    func expiryIsReadFromTheStoredDate() {
        #expect(makeToken(expiresAt: nil).isExpired == false)
        #expect(makeToken(expiresAt: Date.now.addingTimeInterval(3_600)).isExpired == false)
        #expect(makeToken(expiresAt: Date.now.addingTimeInterval(-1)).isExpired)
    }

    @Test("A token is effectively active only while it is both active and unexpired")
    func effectivelyActiveNeedsBoth() {
        #expect(makeToken(isActive: true, expiresAt: nil).isEffectivelyActive)
        #expect(makeToken(isActive: true, expiresAt: Date.now.addingTimeInterval(-1)).isEffectivelyActive == false)
        #expect(makeToken(isActive: false, expiresAt: nil).isEffectivelyActive == false)
    }

    @Test("Minting states the grant: the connection scope and the expiry are both recorded")
    func mintingRecordsTheGrant() async throws {
        let store = makeStore()
        let allowed: Set<UUID> = [UUID(), UUID()]
        let expiry = Date.now.addingTimeInterval(3_600)

        let result = try await store.generate(
            name: "scoped",
            permissions: .readOnly,
            connectionAccess: .limited(allowed),
            expiresAt: expiry
        )

        #expect(result.token.connectionAccess == .limited(allowed))
        #expect(result.token.expiresAt == expiry)
        #expect(result.token.permissions == .readOnly)
        #expect(result.token.isActive)
        #expect(result.plaintext.hasPrefix("tp_"))
        #expect(result.token.prefix == String(result.plaintext.prefix(8)))
    }

    @Test("The default token lifetime is a finite window, not forever")
    func defaultLifetimeIsFinite() {
        #expect(MCPTokenStore.defaultTokenLifetime == 90 * 24 * 60 * 60)
        #expect(MCPTokenStore.defaultTokenLifetime > 0)
    }

    @Test("Minting a token takes its connection scope and expiry with no default to fall back on")
    func generateDeclaresNoDefaultGrant() throws {
        let source = try Self.tokenStoreSource()
        let signature = try #require(
            source.range(of: #"func generate\([^)]*\)"#, options: .regularExpression).map { String(source[$0]) }
        )

        #expect(signature.contains("connectionAccess: ConnectionAccess"))
        #expect(signature.contains("expiresAt: Date?"))
        #expect(signature.contains("connectionAccess: ConnectionAccess = ") == false)
        #expect(signature.contains("expiresAt: Date? = ") == false)
        #expect(signature.contains("=") == false)
    }

    @Test("Two generated tokens never share a secret or a salt")
    func generatedSecretsAreUnique() async throws {
        let store = makeStore()

        let first = try await store.generate(
            name: "token-1",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )
        let second = try await store.generate(
            name: "token-2",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )

        #expect(first.plaintext != second.plaintext)
        #expect(first.token.salt != second.token.salt)
        #expect(first.token.tokenHash != second.token.tokenHash)
        #expect(first.token.tokenHash != first.plaintext)
    }

    @Test("The stored blob holds a hash, never the token itself")
    func persistedBlobHoldsNoSecret() async throws {
        let credentials = InMemoryCredentialStore()
        let store = makeStore(credentials)

        let result = try await store.generate(
            name: "persisted",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )

        let text = credentials.storedText
        #expect(text.contains(result.token.tokenHash))
        #expect(text.contains(result.plaintext) == false)
        #expect(text.contains(String(result.plaintext.dropFirst(8))) == false)
    }

    @Test("Validation accepts the matching secret and refuses everything else")
    func validationMatchesOnlyTheIssuedSecret() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "valid",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )

        #expect(await store.validate(bearerToken: result.plaintext)?.id == result.token.id)
        #expect(await store.validate(bearerToken: "tp_wrong") == nil)
        #expect(await store.validate(bearerToken: result.token.prefix) == nil)
    }

    @Test("An expired token no longer validates")
    func expiredTokenDoesNotValidate() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "expired",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: Date.now.addingTimeInterval(-1)
        )

        #expect(await store.validate(bearerToken: result.plaintext) == nil)
        #expect(await store.activeTokens().contains(where: { $0.id == result.token.id }) == false)
    }

    @Test("A revoked token no longer validates and stays listed as inactive")
    func revokedTokenDoesNotValidate() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "revoked",
            permissions: .readWrite,
            connectionAccess: .all,
            expiresAt: nil
        )

        await store.revoke(tokenId: result.token.id)

        #expect(await store.validate(bearerToken: result.plaintext) == nil)
        #expect(await store.token(id: result.token.id)?.isActive == false)
        #expect(await store.activeTokens().isEmpty)
    }

    @Test("Validating stamps the last use onto the token")
    func validationStampsLastUse() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "used",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )

        _ = await store.validate(bearerToken: result.plaintext)

        #expect(await store.token(id: result.token.id)?.lastUsedAt != nil)
    }

    @Test("Revoking announces the token id to the observers that watch for it")
    func revocationNotifiesObservers() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "observed",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )
        let recorder = RevocationRecorder()
        await store.addRevocationObserver { key in
            await recorder.append(key)
        }

        await store.revoke(tokenId: result.token.id)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.keys().contains(result.token.id.uuidString))
    }

    @Test("Deleting drops the token from the list entirely")
    func deleteRemovesTheToken() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "temporary",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )

        await store.delete(tokenId: result.token.id)

        #expect(await store.list().contains(where: { $0.id == result.token.id }) == false)
        #expect(await store.validate(bearerToken: result.plaintext) == nil)
    }

    @Test("A second token claiming the same client name leaves the first one working")
    func sameClientNameDoesNotRevokeTheStandingToken() async throws {
        let store = makeStore()
        let standing = try await store.generate(
            name: "Claude",
            permissions: .readWrite,
            connectionAccess: .all,
            expiresAt: nil
        )

        let impostor = try await store.generate(
            name: "Claude",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )

        #expect(impostor.token.id != standing.token.id)
        #expect(await store.validate(bearerToken: standing.plaintext)?.id == standing.token.id)
        #expect(await store.token(id: standing.token.id)?.isActive == true)
        #expect(await store.activeTokens().count == 2)
    }

    @Test("Tokens survive a reload through the credential store")
    func tokensRoundTripThroughTheCredentialStore() async throws {
        let credentials = InMemoryCredentialStore()
        let writer = makeStore(credentials)
        let result = try await writer.generate(
            name: "persisted",
            permissions: .fullAccess,
            connectionAccess: .limited([UUID()]),
            expiresAt: nil
        )

        let reader = makeStore(credentials)
        await reader.loadFromDisk()

        let reloaded = try #require(await reader.token(id: result.token.id))
        #expect(reloaded.name == "persisted")
        #expect(reloaded.permissions == .fullAccess)
        #expect(reloaded.connectionAccess == result.token.connectionAccess)
        #expect(await reader.validate(bearerToken: result.plaintext)?.id == result.token.id)
    }

    @Test("A stale bridge credential is cleaned out on load")
    func staleBridgeTokensAreDroppedOnLoad() async throws {
        let credentials = InMemoryCredentialStore()
        let writer = makeStore(credentials)
        _ = try await writer.generate(
            name: MCPTokenStore.stdioBridgeTokenName,
            permissions: MCPTokenStore.bridgeTokenPermissions,
            connectionAccess: .all,
            expiresAt: Date.now.addingTimeInterval(3_600)
        )
        let survivor = try await writer.generate(
            name: "user token",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil
        )

        let reader = makeStore(credentials)
        await reader.loadFromDisk()

        let names = await reader.list().map(\.name)
        #expect(names == ["user token"])
        #expect(await reader.token(id: survivor.token.id) != nil)
    }

    @Test("A limited grant answers only for the connections it names")
    func limitedGrantAnswersForItsConnectionsOnly() {
        let allowed = UUID()
        let access = ConnectionAccess.limited([allowed])

        #expect(access.allows(allowed))
        #expect(access.allows(UUID()) == false)
        #expect(ConnectionAccess.all.allows(UUID()))
    }

    private static func tokenStoreSource() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = directory
                .appendingPathComponent("TablePro/Core/MCP/MCPTokenStore.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

private actor RevocationRecorder {
    private var received: [String] = []

    func append(_ key: String) {
        received.append(key)
    }

    func keys() -> [String] {
        received
    }
}
