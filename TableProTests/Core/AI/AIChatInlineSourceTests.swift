//
//  AIChatInlineSourceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
private final class InlinePolicyBox {
    var policy: AIConnectionPolicy?

    init(_ policy: AIConnectionPolicy?) {
        self.policy = policy
    }
}

private final class RecordingTransport: ChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentTurns: [[ChatTurnWire]] = []

    var requestCount: Int {
        lock.withLock { sentTurns.count }
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        lock.withLock { sentTurns.append(turns) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("FROM users"))
            continuation.finish()
        }
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] { [] }

    func testConnection() async throws -> Bool { true }
}

@MainActor
internal struct AIChatInlineSourceTests {
    private let connectionId = UUID()
    private let approvals = AIAccessApprovals()
    private let transport = RecordingTransport()
    private let providerConfig = AIProviderConfig(name: "Test", type: .claude)

    private var settings: AISettings {
        AISettings(
            enabled: true,
            providers: [providerConfig],
            activeProviderID: providerConfig.id,
            inlineSuggestionsEnabled: true,
            includeSchema: false
        )
    }

    private let context = SuggestionContext(
        textBefore: "SELECT * ",
        fullText: "SELECT * ",
        cursorOffset: 9,
        cursorLine: 0,
        cursorCharacter: 9
    )

    private func makeSource(
        _ box: InlinePolicyBox,
        onResolveProvider: @escaping @MainActor () -> Void = {}
    ) -> AIChatInlineSource {
        let resolved = AIProviderFactory.ResolvedProvider(provider: transport, model: "test-model", config: providerConfig)
        let current = settings
        return AIChatInlineSource(
            schemaProvider: nil,
            connectionId: connectionId,
            accessGate: AIConnectionAccessGate(approvals: approvals) { _ in box.policy },
            currentSettings: { current },
            resolveProvider: { _ in
                onResolveProvider()
                return resolved
            }
        )
    }

    @Test("Always Allow sends the request and shows the suggestion")
    func alwaysAllowSends() async throws {
        let source = makeSource(InlinePolicyBox(.alwaysAllow))

        let suggestion = try await source.requestSuggestion(context: context)

        #expect(source.isAvailable)
        #expect(suggestion?.text == "FROM users")
        #expect(transport.requestCount == 1)
    }

    @Test("Never sends nothing and reports the source unavailable")
    func neverSendsNothing() async throws {
        let source = makeSource(InlinePolicyBox(.never))

        let suggestion = try await source.requestSuggestion(context: context)

        #expect(!source.isAvailable)
        #expect(suggestion == nil)
        #expect(transport.requestCount == 0)
    }

    @Test("Ask Each Time sends nothing until the connection is approved, then sends")
    func askEachTimeWaitsForApproval() async throws {
        let source = makeSource(InlinePolicyBox(.askEachTime))

        _ = try await source.requestSuggestion(context: context)
        #expect(!source.isAvailable)
        #expect(transport.requestCount == 0)

        approvals.approve(connectionId)
        _ = try await source.requestSuggestion(context: context)
        #expect(source.isAvailable)
        #expect(transport.requestCount == 1)
    }

    @Test("A policy changed to Never after the source was built stops the next request")
    func policyChangedAfterCreationStopsRequests() async throws {
        let box = InlinePolicyBox(.alwaysAllow)
        let source = makeSource(box)

        _ = try await source.requestSuggestion(context: context)
        #expect(transport.requestCount == 1)

        box.policy = .never
        let suggestion = try await source.requestSuggestion(context: context)

        #expect(!source.isAvailable)
        #expect(suggestion == nil)
        #expect(transport.requestCount == 1)
    }

    @Test("A policy changed to Never while the request is being prepared sends nothing")
    func policyChangedMidRequestSendsNothing() async throws {
        let box = InlinePolicyBox(.alwaysAllow)
        let source = makeSource(box) { box.policy = .never }

        let suggestion = try await source.requestSuggestion(context: context)

        #expect(suggestion == nil)
        #expect(transport.requestCount == 0)
    }

    @Test("An approval revoked by a disconnect stops the next request")
    func revokedApprovalStopsRequests() async throws {
        let source = makeSource(InlinePolicyBox(.askEachTime))
        approvals.approve(connectionId)

        _ = try await source.requestSuggestion(context: context)
        #expect(transport.requestCount == 1)

        approvals.revoke(connectionId)
        _ = try await source.requestSuggestion(context: context)
        #expect(transport.requestCount == 1)
    }
}

internal struct InlineSuggestionSourceKindTests {
    private func settings(providerType: AIProviderType, inlineEnabled: Bool = true) -> AISettings {
        let provider = AIProviderConfig(name: "Test", type: providerType)
        return AISettings(
            enabled: true,
            providers: [provider],
            activeProviderID: provider.id,
            inlineSuggestionsEnabled: inlineEnabled
        )
    }

    @Test("Copilot is switched off on a connection the AI policy keeps closed")
    func copilotFollowsTheGate() {
        let copilot = settings(providerType: .copilot)

        #expect(InlineSuggestionSourceKind.resolve(settings: copilot, accessAllowed: false) == .off)
        #expect(InlineSuggestionSourceKind.resolve(settings: copilot, accessAllowed: true) == .copilot)
    }

    @Test("A chat provider is switched off on a connection the AI policy keeps closed")
    func chatCompletionFollowsTheGate() {
        let claude = settings(providerType: .claude)

        #expect(InlineSuggestionSourceKind.resolve(settings: claude, accessAllowed: false) == .off)
        #expect(InlineSuggestionSourceKind.resolve(settings: claude, accessAllowed: true) == .chatCompletion)
    }

    @Test("Inline suggestions turned off stay off whatever the policy")
    func inlineDisabledStaysOff() {
        let disabled = settings(providerType: .claude, inlineEnabled: false)

        #expect(InlineSuggestionSourceKind.resolve(settings: disabled, accessAllowed: true) == .off)
    }
}
