//
//  ChatGPTCodexTokenStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private actor FakeRefresher: ChatGPTCodexTokenRefreshing {
    private(set) var callCount = 0
    private let response: ChatGPTCodexTokenResponse
    private let delayNanos: UInt64

    init(response: ChatGPTCodexTokenResponse, delayNanos: UInt64 = 0) {
        self.response = response
        self.delayNanos = delayNanos
    }

    func refresh(refreshToken: String) async throws -> ChatGPTCodexTokenResponse {
        callCount += 1
        if delayNanos > 0 {
            try? await Task.sleep(nanoseconds: delayNanos)
        }
        return response
    }
}

@Suite("ChatGPTCodexTokenStore")
struct ChatGPTCodexTokenStoreTests {
    private func tokens(
        refresh: String = "r",
        expiresIn: TimeInterval,
        account: String = "acct"
    ) -> ChatGPTCodexTokens {
        ChatGPTCodexTokens(
            accessToken: "access",
            refreshToken: refresh,
            idToken: "",
            accountID: account,
            email: "dev@example.com",
            planType: "plus",
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private func response(
        access: String,
        refresh: String,
        expiresIn: TimeInterval
    ) -> ChatGPTCodexTokenResponse {
        ChatGPTCodexTokenResponse(
            accessToken: access,
            refreshToken: refresh,
            idToken: "",
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    @Test("Saved tokens round-trip through Keychain storage")
    func saveAndLoadRoundTrip() async {
        let store = ChatGPTCodexTokenStore(
            keychain: InMemoryKeychain(),
            refresher: FakeRefresher(response: response(access: "a", refresh: "r", expiresIn: 600))
        )
        await store.save(tokens(expiresIn: 600))
        let loaded = await store.currentTokens()
        #expect(loaded?.accessToken == "access")
        #expect(loaded?.accountID == "acct")
        #expect(await store.isSignedIn())
    }

    @Test("A valid token is returned without refreshing")
    func notExpiredSkipsRefresh() async throws {
        let refresher = FakeRefresher(response: response(access: "new", refresh: "r2", expiresIn: 600))
        let store = ChatGPTCodexTokenStore(keychain: InMemoryKeychain(), refresher: refresher)
        await store.save(tokens(expiresIn: 600))
        let token = try await store.validAccessToken()
        #expect(token == "access")
        #expect(await refresher.callCount == 0)
    }

    @Test("A token inside the 60s skew window triggers a refresh")
    func expirySkewTriggersRefresh() async throws {
        let refresher = FakeRefresher(response: response(access: "fresh", refresh: "r2", expiresIn: 600))
        let store = ChatGPTCodexTokenStore(keychain: InMemoryKeychain(), refresher: refresher)
        await store.save(tokens(expiresIn: 30))
        let token = try await store.validAccessToken()
        #expect(token == "fresh")
        #expect(await refresher.callCount == 1)
    }

    @Test("A rotated refresh token is persisted")
    func refreshTokenRotationPersisted() async throws {
        let refresher = FakeRefresher(response: response(access: "fresh", refresh: "rotated", expiresIn: 600))
        let store = ChatGPTCodexTokenStore(keychain: InMemoryKeychain(), refresher: refresher)
        await store.save(tokens(refresh: "old", expiresIn: -10))
        _ = try await store.validAccessToken()
        let current = await store.currentTokens()
        #expect(current?.refreshToken == "rotated")
    }

    @Test("Concurrent callers share a single refresh")
    func singleFlightRefresh() async throws {
        let refresher = FakeRefresher(
            response: response(access: "fresh", refresh: "r2", expiresIn: 600),
            delayNanos: 80_000_000
        )
        let store = ChatGPTCodexTokenStore(keychain: InMemoryKeychain(), refresher: refresher)
        await store.save(tokens(expiresIn: -10))
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await store.validAccessToken() }
            }
            for try await _ in group {}
        }
        #expect(await refresher.callCount == 1)
    }

    @Test("Clearing removes the stored session")
    func clearRemovesTokens() async {
        let store = ChatGPTCodexTokenStore(
            keychain: InMemoryKeychain(),
            refresher: FakeRefresher(response: response(access: "a", refresh: "r", expiresIn: 600))
        )
        await store.save(tokens(expiresIn: 600))
        await store.clear()
        #expect(await store.currentTokens() == nil)
        #expect(await store.isSignedIn() == false)
    }
}
