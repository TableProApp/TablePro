//
//  MCPPairingServiceTests.swift
//  TableProTests
//
//  A pairing code is a bearer credential for the whole grant, so each code allows exactly one
//  attempt: a verifier that does not match burns the code instead of leaving it alive for the rest
//  of the five-minute window, which is what turned PKCE into an offline guessing game. The record
//  carries the token id so a caller that fails the exchange can delete the token it was holding.
//

import CryptoKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Pairing Exchange Store")
struct MCPPairingServiceTests {
    private func challenge(for verifier: String) -> String {
        PairingExchangeStore.sha256Base64Url(of: verifier)
    }

    private func makeVerifier(_ seed: Character = "a") -> String {
        String(repeating: seed, count: PairingPkceValidator.minimumVerifierLength)
    }

    private func makeRecord(
        plaintext: String = "tp_secret",
        tokenId: UUID = UUID(),
        challenge: String,
        expiresIn: TimeInterval = 60
    ) -> PairingExchangeRecord {
        PairingExchangeRecord(
            plaintextToken: plaintext,
            tokenId: tokenId,
            challenge: challenge,
            expiresAt: Date.now.addingTimeInterval(expiresIn)
        )
    }

    @Test("A matching verifier releases the token and the id that issued it")
    func matchingVerifierReleasesTheGrant() async throws {
        let store = PairingExchangeStore()
        let verifier = makeVerifier()
        let tokenId = UUID()
        try await store.insert(
            code: "code-1",
            record: makeRecord(tokenId: tokenId, challenge: challenge(for: verifier))
        )

        let record = try await store.consume(code: "code-1", verifier: verifier)

        #expect(record.plaintextToken == "tp_secret")
        #expect(record.tokenId == tokenId)
    }

    @Test("A code is single use")
    func consumeIsSingleUse() async throws {
        let store = PairingExchangeStore()
        let verifier = makeVerifier()
        try await store.insert(code: "code-2", record: makeRecord(challenge: challenge(for: verifier)))

        _ = try await store.consume(code: "code-2", verifier: verifier)

        #expect(await store.contains(code: "code-2") == false)
        await #expect(throws: DatabaseAccessError.self) {
            _ = try await store.consume(code: "code-2", verifier: verifier)
        }
    }

    @Test("A failed verification burns the code, so the right verifier cannot follow it")
    func failedVerificationBurnsTheCode() async throws {
        let store = PairingExchangeStore()
        let verifier = makeVerifier()
        try await store.insert(code: "code-3", record: makeRecord(challenge: challenge(for: verifier)))

        do {
            _ = try await store.consume(code: "code-3", verifier: makeVerifier("b"))
            Issue.record("Expected the mismatched verifier to be refused")
        } catch let error as DatabaseAccessError {
            guard case .forbidden = error else {
                Issue.record("Expected forbidden, got \(error)")
                return
            }
        }

        #expect(await store.contains(code: "code-3") == false)
        await #expect(throws: DatabaseAccessError.self) {
            _ = try await store.consume(code: "code-3", verifier: verifier)
        }
    }

    @Test("An unknown code is not found")
    func unknownCodeIsNotFound() async {
        let store = PairingExchangeStore()

        do {
            _ = try await store.consume(code: "missing", verifier: makeVerifier())
            Issue.record("Expected notFound")
        } catch let error as DatabaseAccessError {
            guard case .notFound = error else {
                Issue.record("Expected notFound, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An expired code is refused and dropped")
    func expiredCodeIsRefusedAndDropped() async throws {
        let store = PairingExchangeStore()
        let verifier = makeVerifier()
        try await store.insert(
            code: "code-4",
            record: makeRecord(challenge: challenge(for: verifier), expiresIn: -1)
        )

        do {
            _ = try await store.consume(code: "code-4", verifier: verifier, now: Date.now)
            Issue.record("Expected expired")
        } catch let error as DatabaseAccessError {
            guard case .expired = error else {
                Issue.record("Expected expired, got \(error)")
                return
            }
        }

        #expect(await store.contains(code: "code-4") == false)
    }

    @Test("Discarding a code removes it without an exchange")
    func discardRemovesTheCode() async throws {
        let store = PairingExchangeStore()
        let verifier = makeVerifier()
        try await store.insert(code: "code-5", record: makeRecord(challenge: challenge(for: verifier)))

        await store.discard(code: "code-5")

        #expect(await store.contains(code: "code-5") == false)
        #expect(await store.count() == 0)
    }

    @Test("Pruning removes the expired codes and keeps the live one")
    func pruneRemovesOnlyExpiredEntries() async throws {
        let store = PairingExchangeStore()
        try await store.insert(code: "alive", record: makeRecord(challenge: "challenge", expiresIn: 60))
        try await store.insert(code: "stale-1", record: makeRecord(challenge: "challenge", expiresIn: -1))
        try await store.insert(code: "stale-2", record: makeRecord(challenge: "challenge", expiresIn: -10))

        await store.pruneExpired()

        #expect(await store.count() == 1)
        #expect(await store.contains(code: "alive"))
        #expect(await store.contains(code: "stale-1") == false)
        #expect(await store.contains(code: "stale-2") == false)
    }

    @Test("The challenge is the base64url SHA-256 of the verifier, unpadded")
    func challengeMatchesCryptoKit() {
        let value = "verifier-string"
        let expected = Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(PairingExchangeStore.sha256Base64Url(of: value) == expected)
        #expect(PairingExchangeStore.sha256Base64Url(of: value).count == PairingPkceValidator.challengeLength)
    }

    @Test("The challenge comparison is length-safe and value-exact")
    func constantTimeComparison() {
        #expect(PairingExchangeStore.constantTimeEqual("abc", "abc"))
        #expect(PairingExchangeStore.constantTimeEqual("abc", "abd") == false)
        #expect(PairingExchangeStore.constantTimeEqual("abc", "abcd") == false)
        #expect(PairingExchangeStore.constantTimeEqual("", ""))
    }

    @Test("Pending codes are capped so a caller cannot fill the store")
    func pendingCodesAreCapped() async throws {
        let store = PairingExchangeStore()
        for index in 0..<PairingExchangeStore.maxPendingCodes {
            try await store.insert(code: "code-cap-\(index)", record: makeRecord(challenge: "challenge"))
        }

        do {
            try await store.insert(code: "code-overflow", record: makeRecord(challenge: "challenge"))
            Issue.record("Expected the pending cap to refuse another code")
        } catch let error as DatabaseAccessError {
            guard case .forbidden = error else {
                Issue.record("Expected forbidden, got \(error)")
                return
            }
        }

        #expect(await store.count() == PairingExchangeStore.maxPendingCodes)
        #expect(await store.contains(code: "code-overflow") == false)
    }

    @Test("The exchange window is the five minutes the client is told about")
    func exchangeWindowIsFiveMinutes() {
        #expect(PairingExchangeStore.exchangeWindow == 300)
    }

    @Test("A repeated exchange attempt is rate limited per address")
    @MainActor
    func exchangeAttemptsAreRateLimited() async {
        let limiter = MCPRateLimiter(
            pairingPolicy: MCPPairingService.exchangeRateLimitPolicy,
            clock: MCPTestClock()
        )
        let key = MCPRateLimitKey.pairingExchange(address: .loopback)

        for _ in 0..<4 {
            #expect(await limiter.recordAttempt(key: key, success: false) == .allowed)
        }

        guard case .lockedUntil = await limiter.recordAttempt(key: key, success: false) else {
            Issue.record("Expected the pairing exchange bucket to lock")
            return
        }
        #expect(await limiter.isLocked(key: key))
    }
}
