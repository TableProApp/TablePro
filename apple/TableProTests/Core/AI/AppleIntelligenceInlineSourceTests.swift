//
//  AppleIntelligenceInlineSourceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private final class PolicySwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AIConnectionPolicy

    init(_ policy: AIConnectionPolicy) {
        current = policy
    }

    var policy: AIConnectionPolicy {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

@MainActor
internal struct AppleIntelligenceInlineSourceTests {
    private let connectionId = UUID()
    private let approvals = AIAccessApprovals()

    private let context = SuggestionContext(
        textBefore: "SELECT * ",
        fullText: "SELECT * ",
        cursorOffset: 9,
        cursorLine: 0,
        cursorCharacter: 9
    )

    private func makeSource(
        _ model: FakeOnDeviceModel,
        policy: AIConnectionPolicy = .alwaysAllow,
        useAppleIntelligence: Bool = true
    ) -> AppleIntelligenceInlineSource {
        makeSource(model, policy: PolicySwitch(policy), useAppleIntelligence: useAppleIntelligence)
    }

    private func makeSource(
        _ model: FakeOnDeviceModel,
        policy: PolicySwitch,
        useAppleIntelligence: Bool = true
    ) -> AppleIntelligenceInlineSource {
        let settings = AISettings(
            enabled: true,
            inlineSuggestionsEnabled: true,
            useAppleIntelligence: useAppleIntelligence,
            includeSchema: false
        )
        return AppleIntelligenceInlineSource(
            schemaProvider: nil,
            connectionId: connectionId,
            accessGate: AIConnectionAccessGate(approvals: approvals) { _ in policy.policy },
            currentSettings: { settings },
            model: model
        )
    }

    @Test("A suggestion comes from the on-device model, cleaned, with the reply kept short")
    func suggestsOnDevice() async throws {
        let model = FakeOnDeviceModel(reply: ["\nFROM ", "users  \n"])
        let source = makeSource(model)

        let suggestion = try await source.requestSuggestion(context: context)

        #expect(source.isAvailable)
        #expect(suggestion?.text == "FROM users")
        let streamed = try #require(model.streamedRequests.first)
        #expect(streamed.request.prompt.contains("SELECT * [CURSOR]"))
        #expect(streamed.maximumResponseTokens == AppleIntelligenceInlineSource.replyTokenLimit)
    }

    @Test("A model that cannot run, a Never connection or the setting off sends nothing", arguments: [
        (AppleIntelligenceAvailability.unavailable(.modelNotReady), AIConnectionPolicy.alwaysAllow, true),
        (.available, .never, true),
        (.available, .alwaysAllow, false)
    ])
    func unavailableSendsNothing(
        availability: AppleIntelligenceAvailability,
        policy: AIConnectionPolicy,
        enabled: Bool
    ) async throws {
        let model = FakeOnDeviceModel(availability: availability)
        let source = makeSource(model, policy: policy, useAppleIntelligence: enabled)

        let suggestion = try await source.requestSuggestion(context: context)

        #expect(!source.isAvailable)
        #expect(suggestion == nil)
        #expect(model.countedRequests.isEmpty)
        #expect(model.streamedRequests.isEmpty)
    }

    @Test("A policy turned to Never while the request is measured stops it before generation")
    func policyChangedWhileMeasuringSendsNothing() async throws {
        let policy = PolicySwitch(.alwaysAllow)
        let model = FakeOnDeviceModel { _ in
            policy.policy = .never
            return 10
        }
        let source = makeSource(model, policy: policy)

        let suggestion = try await source.requestSuggestion(context: context)

        #expect(suggestion == nil)
        #expect(model.countedRequests.count == 1)
        #expect(model.streamedRequests.isEmpty)
    }

    @Test("A request too large for the model is dropped before generation")
    func tooLargeIsDropped() async throws {
        let model = FakeOnDeviceModel(contextSize: 300) { _ in 200 }
        let source = makeSource(model)

        let suggestion = try await source.requestSuggestion(context: context)

        #expect(suggestion == nil)
        #expect(model.countedRequests.count == 1)
        #expect(model.streamedRequests.isEmpty)
    }
}
