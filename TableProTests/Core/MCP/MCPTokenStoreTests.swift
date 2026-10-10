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
            expiresAt: expiry,
            isBridgeCredential: false,
            extraScopes: []
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
        #expect(signature.contains("isBridgeCredential: Bool"))
        #expect(signature.contains("extraScopes: Set<MCPScope>"))
        #expect(signature.contains("connectionAccess: ConnectionAccess = ") == false)
        #expect(signature.contains("expiresAt: Date? = ") == false)
        #expect(signature.contains("isBridgeCredential: Bool = ") == false)
        #expect(signature.contains("=") == false)
    }

    @Test("Two generated tokens never share a secret or a salt")
    func generatedSecretsAreUnique() async throws {
        let store = makeStore()

        let first = try await store.generate(
            name: "token-1",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )
        let second = try await store.generate(
            name: "token-2",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
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
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
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
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
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
            expiresAt: Date.now.addingTimeInterval(-1),
            isBridgeCredential: false,
            extraScopes: []
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
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )

        await store.revoke(tokenId: result.token.id)

        #expect(await store.validate(bearerToken: result.plaintext) == nil)
        #expect(await store.token(id: result.token.id)?.isActive == false)
        #expect(await store.activeTokens().isEmpty)
    }

    @Test("An expired token is refused as expired, not unknown, and its last use is not stamped")
    func expiredTokenIsRefusedAsExpired() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "expired",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: Date.now.addingTimeInterval(-1),
            isBridgeCredential: false,
            extraScopes: []
        )

        #expect(await store.validateBearerToken(result.plaintext) == .failure(.expired))
        #expect(await store.token(id: result.token.id)?.lastUsedAt == nil)
    }

    @Test("A revoked token is refused as revoked, not unknown, and its last use is not stamped")
    func revokedTokenIsRefusedAsRevoked() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "revoked",
            permissions: .readWrite,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )

        await store.revoke(tokenId: result.token.id)

        #expect(await store.validateBearerToken(result.plaintext) == .failure(.revoked))
        #expect(await store.token(id: result.token.id)?.lastUsedAt == nil)
    }

    @Test("An expired token from the store reaches the client as -33008 with the token expired challenge")
    func expiredTokenReachesTheClientAsExpired() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "expired",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: Date.now.addingTimeInterval(-1),
            isBridgeCredential: false,
            extraScopes: []
        )
        let authenticator = MCPBearerTokenAuthenticator(
            tokenStore: store,
            rateLimiter: MCPRateLimiter(clock: MCPTestClock())
        )

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(result.plaintext)",
            clientAddress: .loopback
        )

        guard case .deny(let reason) = decision else {
            Issue.record("Expected a denial, got \(decision)")
            return
        }
        #expect(reason.asProtocolError.code == JsonRpcErrorCode.expired)
        #expect(reason.challenge?.headerValue.contains("error_description=\"token expired\"") == true)
    }

    @Test("A string that matches no stored token is refused as unknown")
    func unmatchedBearerIsUnknown() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "valid",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )

        #expect(await store.validateBearerToken("tp_wrong") == .failure(.unknownToken))
        #expect(await store.validateBearerToken(result.token.prefix) == .failure(.unknownToken))
    }

    @Test("Validating stamps the last use onto the token")
    func validationStampsLastUse() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: "used",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
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
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )
        let recorder = RevocationRecorder()
        await store.addRevocationObserver { key, _ in
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
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
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
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )

        let impostor = try await store.generate(
            name: "Claude",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
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
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
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
            expiresAt: Date.now.addingTimeInterval(3_600),
            isBridgeCredential: true,
            extraScopes: []
        )
        let survivor = try await writer.generate(
            name: "user token",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )

        let reader = makeStore(credentials)
        await reader.loadFromDisk()

        let names = await reader.list().map(\.name)
        #expect(names == ["user token"])
        #expect(await reader.token(id: survivor.token.id) != nil)
    }

    @Test("An optional grant survives a reload and adds to the tier's scopes")
    func extraScopesRoundTrip() async throws {
        let credentials = InMemoryCredentialStore()
        let writer = makeStore(credentials)
        let result = try await writer.generate(
            name: "launcher",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: [.connectionsDisplay]
        )

        let reader = makeStore(credentials)
        await reader.loadFromDisk()

        let reloaded = try #require(await reader.token(id: result.token.id))
        #expect(reloaded.extraScopes == [.connectionsDisplay])
        #expect(reloaded.scopes == MCPScope.readOnlySet.union([.connectionsDisplay]))
        #expect(credentials.storedText.contains(#""extraScopes":["connections:display"]"#))
    }

    @Test("A token saved before optional grants existed reads back with none")
    func missingExtraScopesDecodeEmpty() async throws {
        let credentials = InMemoryCredentialStore()
        let writer = makeStore(credentials)
        let result = try await writer.generate(
            name: "old",
            permissions: .readWrite,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )
        #expect(credentials.storedText.contains("extraScopes") == false)

        let reader = makeStore(credentials)
        await reader.loadFromDisk()

        let reloaded = try #require(await reader.token(id: result.token.id))
        #expect(reloaded.extraScopes.isEmpty)
        #expect(reloaded.scopes == MCPScope.readWriteSet)
    }

    @Test("A tier scope written into the optional grants is dropped, and a bad value costs only that field")
    func extraScopesAcceptOnlyOptionalGrants() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func decode(_ extra: String) throws -> MCPAuthToken {
            let json = """
                {"id":"\(UUID().uuidString)","name":"t","prefix":"tp_abc12","tokenHash":"h","salt":"s",\
                "permissions":"readOnly","createdAt":"2026-10-10T00:00:00Z","isActive":true\(extra)}
                """
            return try decoder.decode(MCPAuthToken.self, from: Data(json.utf8))
        }

        let smuggled = try decode(#","extraScopes":["admin","tools:write","connections:display"]"#)
        #expect(smuggled.extraScopes == [.connectionsDisplay])
        #expect(smuggled.scopes.contains(.admin) == false)
        #expect(smuggled.scopes.contains(.toolsWrite) == false)

        let malformed = try decode(#","extraScopes":"connections:display""#)
        #expect(malformed.extraScopes.isEmpty)
    }

    @Test("The bridge credential never carries an optional grant")
    func bridgeCredentialGetsNoOptionalGrant() async throws {
        let store = makeStore()
        let result = try await store.generate(
            name: MCPTokenStore.stdioBridgeTokenName,
            permissions: MCPTokenStore.bridgeTokenPermissions,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: true,
            extraScopes: [.connectionsDisplay]
        )
        #expect(result.token.extraScopes.isEmpty)
    }

    @Test("Validating a token reports its tier scopes plus its optional grants")
    func validatedScopesIncludeOptionalGrants() async throws {
        let store = makeStore()
        let plain = try await store.generate(
            name: "agent",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: []
        )
        let launcher = try await store.generate(
            name: "launcher",
            permissions: .readOnly,
            connectionAccess: .all,
            expiresAt: nil,
            isBridgeCredential: false,
            extraScopes: [.connectionsDisplay]
        )

        let plainScopes = try (await store.validateBearerToken(plain.plaintext)).get().scopes
        let launcherScopes = try (await store.validateBearerToken(launcher.plaintext)).get().scopes
        #expect(plainScopes == MCPScope.readOnlySet)
        #expect(launcherScopes == MCPScope.readOnlySet.union([.connectionsDisplay]))
    }

    @Test("No permission level and no built-in principal holds the display scope")
    func displayScopeIsOptInOnly() {
        for permissions in TokenPermissions.allCases {
            #expect(permissions.scopes.contains(.connectionsDisplay) == false)
        }
        #expect(MCPPrincipal.inAppAssistant.has(.connectionsDisplay) == false)
        #expect(MCPPrincipal.anonymousLoopback.has(.connectionsDisplay) == false)
        #expect(MCPPrincipal.inAppAssistant.scopes == MCPScope.fullAccessSet)
        #expect(MCPScope.connectionsDisplay.requiresIssuedToken)
        #expect(MCPScope.optionalGrants == [.connectionsDisplay])
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
