import Foundation
import Testing

@testable import TablePro

@Suite("MCP Token Store")
struct MCPTokenStoreTests {
    private func makeStore() -> MCPTokenStore {
        MCPTokenStore()
    }

    private func makeToken(
        isActive: Bool = true,
        expiresAt: Date? = nil
    ) -> MCPAuthToken {
        MCPAuthToken(
            id: UUID(),
            name: "test-token",
            prefix: "tp_abc12",
            tokenHash: "fakehash",
            salt: "fakesalt",
            permissions: .readOnly,
            allowedConnectionIds: nil,
            createdAt: Date.now,
            lastUsedAt: nil,
            expiresAt: expiresAt,
            isActive: isActive
        )
    }

    @Test("readOnly satisfies readOnly")
    func readOnlySatisfiesReadOnly() {
        #expect(TokenPermissions.readOnly.satisfies(.readOnly) == true)
    }

    @Test("readOnly does not satisfy readWrite")
    func readOnlyDoesNotSatisfyReadWrite() {
        #expect(TokenPermissions.readOnly.satisfies(.readWrite) == false)
    }

    @Test("readOnly does not satisfy fullAccess")
    func readOnlyDoesNotSatisfyFullAccess() {
        #expect(TokenPermissions.readOnly.satisfies(.fullAccess) == false)
    }

    @Test("readWrite satisfies readOnly and readWrite")
    func readWriteSatisfiesReadOnlyAndReadWrite() {
        #expect(TokenPermissions.readWrite.satisfies(.readOnly) == true)
        #expect(TokenPermissions.readWrite.satisfies(.readWrite) == true)
    }

    @Test("readWrite does not satisfy fullAccess")
    func readWriteDoesNotSatisfyFullAccess() {
        #expect(TokenPermissions.readWrite.satisfies(.fullAccess) == false)
    }

    @Test("fullAccess satisfies all permission tiers")
    func fullAccessSatisfiesAllTiers() {
        #expect(TokenPermissions.fullAccess.satisfies(.readOnly) == true)
        #expect(TokenPermissions.fullAccess.satisfies(.readWrite) == true)
        #expect(TokenPermissions.fullAccess.satisfies(.fullAccess) == true)
    }

    @Test("displayName returns non-empty strings for all cases")
    func displayNameReturnsNonEmptyStrings() {
        for permission in TokenPermissions.allCases {
            #expect(permission.displayName.isEmpty == false)
        }
    }

    @Test("CaseIterable has exactly 3 cases")
    func caseIterableHasThreeCases() {
        #expect(TokenPermissions.allCases.count == 3)
    }

    @Test("Identifiable id matches rawValue")
    func identifiableIdMatchesRawValue() {
        #expect(TokenPermissions.readOnly.id == "readOnly")
        #expect(TokenPermissions.readWrite.id == "readWrite")
        #expect(TokenPermissions.fullAccess.id == "fullAccess")
    }

    @Test("isExpired returns false when expiresAt is nil")
    func isExpiredNilExpiresAt() {
        let token = makeToken(expiresAt: nil)
        #expect(token.isExpired == false)
    }

    @Test("isExpired returns false when expiresAt is in the future")
    func isExpiredFutureDate() {
        let token = makeToken(expiresAt: Date.now.addingTimeInterval(3_600))
        #expect(token.isExpired == false)
    }

    @Test("isExpired returns true when expiresAt is in the past")
    func isExpiredPastDate() {
        let token = makeToken(expiresAt: Date.now.addingTimeInterval(-1))
        #expect(token.isExpired == true)
    }

    @Test("isEffectivelyActive returns true when active and not expired")
    func isEffectivelyActiveWhenActiveAndNotExpired() {
        let token = makeToken(isActive: true, expiresAt: nil)
        #expect(token.isEffectivelyActive == true)
    }

    @Test("isEffectivelyActive returns false when active but expired")
    func isEffectivelyActiveWhenActiveButExpired() {
        let token = makeToken(isActive: true, expiresAt: Date.now.addingTimeInterval(-1))
        #expect(token.isEffectivelyActive == false)
    }

    @Test("isEffectivelyActive returns false when inactive and not expired")
    func isEffectivelyActiveWhenInactiveAndNotExpired() {
        let token = makeToken(isActive: false, expiresAt: nil)
        #expect(token.isEffectivelyActive == false)
    }

    @Test("generate creates token with tp_ prefix")
    func generateCreatesTokenWithPrefix() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        await store.delete(tokenId: result.token.id)

        #expect(result.plaintext.hasPrefix("tp_"))
    }

    @Test("generate creates token with correct name")
    func generateCreatesTokenWithCorrectName() async {
        let store = makeStore()
        let result = await store.generate(name: "my-api-key", permissions: .readWrite)
        await store.delete(tokenId: result.token.id)

        #expect(result.token.name == "my-api-key")
    }

    @Test("generate creates token with correct permissions")
    func generateCreatesTokenWithCorrectPermissions() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .fullAccess)
        await store.delete(tokenId: result.token.id)

        #expect(result.token.permissions == .fullAccess)
    }

    @Test("generate stores token prefix as first 8 characters of plaintext")
    func generateStoresTokenPrefix() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        await store.delete(tokenId: result.token.id)

        #expect(result.token.prefix == String(result.plaintext.prefix(8)))
    }

    @Test("generate creates active token")
    func generateCreatesActiveToken() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        await store.delete(tokenId: result.token.id)

        #expect(result.token.isActive == true)
    }

    @Test("generate sets createdAt to approximately now")
    func generateSetsCreatedAtToNow() async {
        let before = Date.now
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        let after = Date.now
        await store.delete(tokenId: result.token.id)

        #expect(result.token.createdAt >= before)
        #expect(result.token.createdAt <= after)
    }

    @Test("generate with expiry stores expiresAt")
    func generateWithExpiry() async {
        let expiry = Date.now.addingTimeInterval(3_600)
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly, expiresAt: expiry)
        await store.delete(tokenId: result.token.id)

        #expect(result.token.expiresAt != nil)
    }

    @Test("generate with nil connectionIds stores nil")
    func generateWithNilConnectionIds() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly, allowedConnectionIds: nil)
        await store.delete(tokenId: result.token.id)

        #expect(result.token.allowedConnectionIds == nil)
    }

    @Test("generate with specific connectionIds stores them")
    func generateWithSpecificConnectionIds() async {
        let ids: Set<UUID> = [UUID(), UUID()]
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly, allowedConnectionIds: ids)
        await store.delete(tokenId: result.token.id)

        #expect(result.token.allowedConnectionIds == ids)
    }

    @Test("validate returns token for valid bearer")
    func validateReturnsTokenForValidBearer() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        let validated = await store.validate(bearerToken: result.plaintext)
        await store.delete(tokenId: result.token.id)

        guard let validated else {
            Issue.record("Expected non-nil validated token")
            return
        }
        #expect(validated.id == result.token.id)
    }

    @Test("validate returns nil for wrong bearer token")
    func validateReturnsNilForWrongBearer() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        let validated = await store.validate(bearerToken: "tp_wrong")
        await store.delete(tokenId: result.token.id)

        #expect(validated == nil)
    }

    @Test("validate returns nil for expired token")
    func validateReturnsNilForExpiredToken() async {
        let store = makeStore()
        let result = await store.generate(
            name: "test",
            permissions: .readOnly,
            expiresAt: Date.now.addingTimeInterval(-1)
        )
        let validated = await store.validate(bearerToken: result.plaintext)
        await store.delete(tokenId: result.token.id)

        #expect(validated == nil)
    }

    @Test("validate returns nil for revoked token")
    func validateReturnsNilForRevokedToken() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        await store.revoke(tokenId: result.token.id)
        let validated = await store.validate(bearerToken: result.plaintext)
        await store.delete(tokenId: result.token.id)

        #expect(validated == nil)
    }

    @Test("validate updates lastUsedAt")
    func validateUpdatesLastUsedAt() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        _ = await store.validate(bearerToken: result.plaintext)
        let tokens = await store.list()
        await store.delete(tokenId: result.token.id)

        guard let updatedToken = tokens.first(where: { $0.id == result.token.id }) else {
            Issue.record("Expected to find token in list")
            return
        }
        #expect(updatedToken.lastUsedAt != nil)
    }

    @Test("revoke sets isActive to false")
    func revokeSetsIsActiveToFalse() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        await store.revoke(tokenId: result.token.id)
        let tokens = await store.list()
        await store.delete(tokenId: result.token.id)

        guard let revokedToken = tokens.first(where: { $0.id == result.token.id }) else {
            Issue.record("Expected to find token in list")
            return
        }
        #expect(revokedToken.isActive == false)
    }

    @Test("delete removes token from list")
    func deleteRemovesTokenFromList() async {
        let store = makeStore()
        let result = await store.generate(name: "test", permissions: .readOnly)
        await store.delete(tokenId: result.token.id)
        let tokens = await store.list()

        #expect(tokens.contains(where: { $0.id == result.token.id }) == false)
    }

    @Test("list returns all generated tokens")
    func listReturnsAllTokens() async {
        let store = makeStore()
        let result1 = await store.generate(name: "token-1", permissions: .readOnly)
        let result2 = await store.generate(name: "token-2", permissions: .readWrite)
        let result3 = await store.generate(name: "token-3", permissions: .fullAccess)
        let tokens = await store.list()

        await store.delete(tokenId: result1.token.id)
        await store.delete(tokenId: result2.token.id)
        await store.delete(tokenId: result3.token.id)

        #expect(tokens.count == 3)
    }

    @Test("activeTokens excludes revoked tokens")
    func activeTokensExcludesRevoked() async {
        let store = makeStore()
        let result1 = await store.generate(name: "active", permissions: .readOnly)
        let result2 = await store.generate(name: "revoked", permissions: .readOnly)
        await store.revoke(tokenId: result2.token.id)
        let active = await store.activeTokens()

        await store.delete(tokenId: result1.token.id)
        await store.delete(tokenId: result2.token.id)

        #expect(active.count == 1)
        #expect(active.first?.id == result1.token.id)
    }

    @Test("activeTokens excludes expired tokens")
    func activeTokensExcludesExpired() async {
        let store = makeStore()
        let result = await store.generate(
            name: "expired",
            permissions: .readOnly,
            expiresAt: Date.now.addingTimeInterval(-1)
        )
        let active = await store.activeTokens()
        await store.delete(tokenId: result.token.id)

        #expect(active.contains(where: { $0.id == result.token.id }) == false)
    }

    @Test("multiple tokens validate independently with their own plaintext")
    func multipleTokensValidateIndependently() async {
        let store = makeStore()
        let result1 = await store.generate(name: "token-1", permissions: .readOnly)
        let result2 = await store.generate(name: "token-2", permissions: .readWrite)

        let validated1 = await store.validate(bearerToken: result1.plaintext)
        let validated2 = await store.validate(bearerToken: result2.plaintext)

        await store.delete(tokenId: result1.token.id)
        await store.delete(tokenId: result2.token.id)

        #expect(validated1?.id == result1.token.id)
        #expect(validated2?.id == result2.token.id)
    }

    @Test("generated token plaintexts are unique")
    func tokenPlaintextsAreUnique() async {
        let store = makeStore()
        let result1 = await store.generate(name: "token-1", permissions: .readOnly)
        let result2 = await store.generate(name: "token-2", permissions: .readOnly)

        await store.delete(tokenId: result1.token.id)
        await store.delete(tokenId: result2.token.id)

        #expect(result1.plaintext != result2.plaintext)
    }
}
