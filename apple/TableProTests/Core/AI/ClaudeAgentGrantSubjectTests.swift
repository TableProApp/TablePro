//
//  ClaudeAgentGrantSubjectTests.swift
//  TableProTests
//
//  The Claude Agent chat mints a token for each turn and deletes it after, so an Ask Once answer
//  filed under the token id was gone by the next turn and the alert came back every time.
//

import Foundation
import TableProMCP
import TableProMCPTestSupport
import TableProTestSupport
import Testing

@testable import TablePro

private final class MemoryTokenCredentials: MCPTokenCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data? = Data("[]".utf8)

    func read() -> MCPTokenBlob {
        lock.withLock { stored.map(MCPTokenBlob.found) ?? .missing }
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.withLock { stored = data }
        return true
    }

    func delete() {
        lock.withLock { stored = nil }
    }
}

private actor EndedTokens {
    private var keys: Set<String> = []

    func record(_ key: String) {
        keys.insert(key)
    }

    func contains(_ key: String) -> Bool {
        keys.contains(key)
    }
}

struct ClaudeAgentGrantSubjectTests {
    private let connectionId = UUID()

    private func mint(
        in store: MCPTokenStore,
        isClaudeAgentCredential: Bool
    ) async throws -> (token: MCPAuthToken, plaintext: String) {
        try await store.generate(
            name: "__claude_agent__",
            permissions: .readOnly,
            connectionAccess: .limited([connectionId]),
            expiresAt: Date.now.addingTimeInterval(900),
            isBridgeCredential: false,
            isClaudeAgentCredential: isClaudeAgentCredential,
            extraScopes: []
        )
    }

    private func principal(presenting plaintext: String, to store: MCPTokenStore) async throws -> MCPPrincipal {
        let clock = MCPTestClock()
        let authenticator = MCPBearerTokenAuthenticator(
            tokenStore: store,
            rateLimiter: MCPRateLimiter(clock: clock),
            clock: clock
        )
        let decision = await authenticator.authenticate(authorizationHeader: "Bearer \(plaintext)", clientAddress: .loopback)
        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            throw CancellationError()
        }
        return principal
    }

    // Clears what each ended token withdraws, as the server manager's observer does.
    private func watch(_ store: MCPTokenStore, clearing ledger: MCPApprovalLedger) async -> EndedTokens {
        let ended = EndedTokens()
        await store.addRevocationObserver { key, withdrawn in
            if let withdrawn {
                await ledger.clear(subject: withdrawn)
            }
            await ended.record(key)
        }
        return ended
    }

    private func approvedTurn(
        in store: MCPTokenStore,
        ledger: MCPApprovalLedger
    ) async throws -> (token: MCPAuthToken, plaintext: String) {
        let minted = try await mint(in: store, isClaudeAgentCredential: true)
        let turn = try await principal(presenting: minted.plaintext, to: store)
        await ledger.record(principal: turn, connectionId: connectionId, approved: true)
        return minted
    }

    @Test("An approval given on one turn still stands on the next turn's token")
    func approvalOutlivesTheTurnToken() async throws {
        let store = MCPTokenStore(credentialStore: MemoryTokenCredentials())
        let ledger = MCPApprovalLedger(clock: MCPTestClock(), store: MCPInMemoryApprovalStore())
        let ended = await watch(store, clearing: ledger)

        let first = try await approvedTurn(in: store, ledger: ledger)
        await store.retire(tokenId: first.token.id)
        let key = first.token.id.uuidString
        try await waitUntil { await ended.contains(key) }

        let second = try await mint(in: store, isClaudeAgentCredential: true)
        let secondTurn = try await principal(presenting: second.plaintext, to: store)

        #expect(secondTurn.grantSubject == .claudeAgent)
        #expect(await ledger.isApproved(principal: secondTurn, connectionId: connectionId))
        #expect(await ledger.isApproved(principal: secondTurn, connectionId: UUID()) == false)
    }

    @Test("Revoking the agent's token in Settings withdraws the approval it was carrying")
    func revokingTheAgentTokenWithdrawsItsApproval() async throws {
        let store = MCPTokenStore(credentialStore: MemoryTokenCredentials())
        let ledger = MCPApprovalLedger(clock: MCPTestClock(), store: MCPInMemoryApprovalStore())
        let ended = await watch(store, clearing: ledger)

        let turn = try await approvedTurn(in: store, ledger: ledger)
        await store.revoke(tokenId: turn.token.id)
        let key = turn.token.id.uuidString
        try await waitUntil { await ended.contains(key) }

        let next = try await mint(in: store, isClaudeAgentCredential: true)
        let nextTurn = try await principal(presenting: next.plaintext, to: store)
        #expect(await ledger.isApproved(principal: nextTurn, connectionId: connectionId) == false)
    }

    @Test("Deleting the agent's token in Settings withdraws the approval it was carrying")
    func deletingTheAgentTokenWithdrawsItsApproval() async throws {
        let store = MCPTokenStore(credentialStore: MemoryTokenCredentials())
        let ledger = MCPApprovalLedger(clock: MCPTestClock(), store: MCPInMemoryApprovalStore())
        let ended = await watch(store, clearing: ledger)

        let turn = try await approvedTurn(in: store, ledger: ledger)
        await store.delete(tokenId: turn.token.id)
        let key = turn.token.id.uuidString
        try await waitUntil { await ended.contains(key) }

        let next = try await mint(in: store, isClaudeAgentCredential: true)
        let nextTurn = try await principal(presenting: next.plaintext, to: store)
        #expect(await ledger.isApproved(principal: nextTurn, connectionId: connectionId) == false)
    }

    @Test("A grant row names the client it belongs to")
    func grantRowsNameTheirClient() {
        let tokenId = UUID()
        let names = [tokenId: "Raycast"]

        #expect(
            MCPGrantListView.clientName(forSubject: MCPGrantSubject.claudeAgent.storageKey, tokenNames: names)
                == AIProviderType.claudeAgent.displayName
        )
        #expect(
            MCPGrantListView.clientName(forSubject: MCPGrantSubject.bridge.storageKey, tokenNames: names)
                == IntegrationsFormatting.displayTokenName(MCPTokenStore.stdioBridgeTokenName)
        )
        #expect(MCPGrantListView.clientName(forSubject: tokenId.uuidString, tokenNames: names) == "Raycast")
        #expect(MCPGrantListView.clientName(forSubject: UUID().uuidString, tokenNames: names) == nil)
    }

    @Test("A token that only takes the agent's name inherits none of its approvals")
    func nameAloneIsNotTheAgent() async throws {
        let store = MCPTokenStore(credentialStore: MemoryTokenCredentials())
        let ledger = MCPApprovalLedger(clock: MCPTestClock(), store: MCPInMemoryApprovalStore())

        let agent = try await mint(in: store, isClaudeAgentCredential: true)
        await ledger.record(
            principal: try await principal(presenting: agent.plaintext, to: store),
            connectionId: connectionId,
            approved: true
        )

        let impostor = try await mint(in: store, isClaudeAgentCredential: false)
        let impostorPrincipal = try await principal(presenting: impostor.plaintext, to: store)

        #expect(impostorPrincipal.grantSubject == .token(impostor.token.id))
        #expect(await ledger.isApproved(principal: impostorPrincipal, connectionId: connectionId) == false)
    }

    @Test("The agent's mark survives a save and reload, and a token saved without it reads as a client")
    func markRoundTrips() async throws {
        let store = MCPTokenStore(credentialStore: MemoryTokenCredentials())
        let agent = try await mint(in: store, isClaudeAgentCredential: true).token
        let client = try await mint(in: store, isClaudeAgentCredential: false).token

        let data = try MCPTokenStore.encodeStored(tokens: [agent, client], undecoded: [])
        let marks = MCPTokenStore.decodeStored(data).tokens.map { $0.isClaudeAgentCredential }
        let mentions = String(bytes: data, encoding: .utf8)?.components(separatedBy: "isClaudeAgentCredential").count

        #expect(marks == [true, false])
        #expect(mentions == 2)
    }
}
