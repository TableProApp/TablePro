import CryptoKit
import Foundation
import Testing

@testable import TablePro

@Suite("MCP Pairing Exchange Store")
struct MCPPairingServiceTests {
    private func base64UrlSha256(of value: String) -> String {
        PairingExchangeStore.sha256Base64Url(of: value)
    }

    private func makeStore() -> PairingExchangeStore {
        PairingExchangeStore()
    }

    private func record(plaintext: String, challenge: String, expiresIn: TimeInterval) -> PairingExchangeRecord {
        PairingExchangeRecord(
            plaintextToken: plaintext,
            challenge: challenge,
            expiresAt: Date.now.addingTimeInterval(expiresIn)
        )
    }

    @Test("consume returns stored token when challenge and verifier match")
    func consumeReturnsTokenForValidVerifier() async throws {
        let verifier = "test-verifier-1"
        let challenge = base64UrlSha256(of: verifier)
        let store = makeStore()
        try await store.insert(code: "code-1", record: record(plaintext: "tp_secret", challenge: challenge, expiresIn: 60))

        let token = try await store.consume(code: "code-1", verifier: verifier)

        #expect(token == "tp_secret")
    }

    @Test("consume removes the entry after success (single-use)")
    func consumeIsSingleUse() async throws {
        let verifier = "test-verifier-2"
        let challenge = base64UrlSha256(of: verifier)
        let store = makeStore()
        try await store.insert(code: "code-2", record: record(plaintext: "tp_secret", challenge: challenge, expiresIn: 60))

        _ = try await store.consume(code: "code-2", verifier: verifier)

        let contains = await store.contains(code: "code-2")
        #expect(contains == false)
    }

    @Test("second consume of the same code returns notFound")
    func duplicateConsumeReturnsNotFound() async throws {
        let verifier = "test-verifier-3"
        let challenge = base64UrlSha256(of: verifier)
        let store = makeStore()
        try await store.insert(code: "code-3", record: record(plaintext: "tp_secret", challenge: challenge, expiresIn: 60))

        _ = try await store.consume(code: "code-3", verifier: verifier)

        await #expect(throws: MCPDataLayerError.self) {
            try await store.consume(code: "code-3", verifier: verifier)
        }
    }

    @Test("consume returns notFound for unknown code")
    func consumeUnknownCodeReturnsNotFound() async {
        let store = makeStore()

        do {
            _ = try await store.consume(code: "missing", verifier: "any")
            Issue.record("Expected notFound error")
        } catch let error as MCPDataLayerError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("consume returns expired when entry has expired")
    func consumeExpiredEntryReturnsExpired() async throws {
        let verifier = "test-verifier-4"
        let challenge = base64UrlSha256(of: verifier)
        let store = makeStore()
        try await store.insert(code: "code-4", record: record(plaintext: "tp_secret", challenge: challenge, expiresIn: -1))

        do {
            _ = try await store.consume(code: "code-4", verifier: verifier, now: Date.now)
            Issue.record("Expected expired error")
        } catch let error as MCPDataLayerError {
            guard case .expired = error else {
                Issue.record("Expected expired, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("consume returns forbidden when challenge does not match the verifier")
    func consumeMismatchedChallengeReturnsForbidden() async throws {
        let store = makeStore()
        let challenge = base64UrlSha256(of: "intended-verifier")
        try await store.insert(code: "code-5", record: record(plaintext: "tp_secret", challenge: challenge, expiresIn: 60))

        do {
            _ = try await store.consume(code: "code-5", verifier: "attacker-verifier")
            Issue.record("Expected forbidden error")
        } catch let error as MCPDataLayerError {
            guard case .forbidden = error else {
                Issue.record("Expected forbidden, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("consume on expired code removes the entry")
    func consumeOnExpiredCodeRemovesEntry() async throws {
        let verifier = "test-verifier-6"
        let challenge = base64UrlSha256(of: verifier)
        let store = makeStore()
        try await store.insert(code: "code-6", record: record(plaintext: "tp_secret", challenge: challenge, expiresIn: -1))

        _ = try? await store.consume(code: "code-6", verifier: verifier)

        let contains = await store.contains(code: "code-6")
        #expect(contains == false)
    }

    @Test("pruneExpired removes only expired entries")
    func pruneRemovesOnlyExpiredEntries() async throws {
        let store = makeStore()
        try await store.insert(
            code: "alive",
            record: record(plaintext: "tp_a", challenge: "challenge", expiresIn: 60)
        )
        try await store.insert(
            code: "stale-1",
            record: record(plaintext: "tp_b", challenge: "challenge", expiresIn: -1)
        )
        try await store.insert(
            code: "stale-2",
            record: record(plaintext: "tp_c", challenge: "challenge", expiresIn: -10)
        )

        await store.pruneExpired()

        let count = await store.count()
        let containsAlive = await store.contains(code: "alive")
        let containsStale1 = await store.contains(code: "stale-1")
        let containsStale2 = await store.contains(code: "stale-2")
        #expect(count == 1)
        #expect(containsAlive)
        #expect(containsStale1 == false)
        #expect(containsStale2 == false)
    }

    @Test("sha256Base64Url matches CryptoKit output without padding")
    func sha256Base64UrlMatchesCryptoKit() {
        let value = "verifier-string"
        let digest = SHA256.hash(data: Data(value.utf8))
        let expected = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(PairingExchangeStore.sha256Base64Url(of: value) == expected)
    }

    @Test("constantTimeEqual returns true for identical strings")
    func constantTimeEqualIdentical() {
        #expect(PairingExchangeStore.constantTimeEqual("abc", "abc"))
    }

    @Test("constantTimeEqual returns false for different strings")
    func constantTimeEqualDifferent() {
        #expect(PairingExchangeStore.constantTimeEqual("abc", "abd") == false)
    }

    @Test("constantTimeEqual returns false for different lengths")
    func constantTimeEqualLengthMismatch() {
        #expect(PairingExchangeStore.constantTimeEqual("abc", "abcd") == false)
    }

    @Test("insert throws after maxPendingCodes consecutive inserts")
    func insertThrowsWhenPendingCapReached() async throws {
        let store = makeStore()
        for index in 0..<PairingExchangeStore.maxPendingCodes {
            try await store.insert(
                code: "code-cap-\(index)",
                record: record(plaintext: "tp_x", challenge: "challenge", expiresIn: 60)
            )
        }

        do {
            try await store.insert(
                code: "code-overflow",
                record: record(plaintext: "tp_x", challenge: "challenge", expiresIn: 60)
            )
            Issue.record("Expected forbidden error after exceeding maxPendingCodes")
        } catch let error as MCPDataLayerError {
            guard case .forbidden = error else {
                Issue.record("Expected forbidden, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let count = await store.count()
        let containsOverflow = await store.contains(code: "code-overflow")
        #expect(count == PairingExchangeStore.maxPendingCodes)
        #expect(containsOverflow == false)
    }
}
