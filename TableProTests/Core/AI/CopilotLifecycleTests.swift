//
//  CopilotLifecycleTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct CopilotLifecycleTests {
    private let copilot = AIProviderConfig(name: "Copilot", type: .copilot)
    private let claude = AIProviderConfig(name: "Claude", type: .claude)

    @Test("Runs only while AI is on and a Copilot provider exists")
    func allowsRunning() {
        #expect(CopilotLifecycle.allowsRunning(AISettings(enabled: true, providers: [copilot])))
        #expect(!CopilotLifecycle.allowsRunning(AISettings(enabled: false, providers: [copilot])))
        #expect(!CopilotLifecycle.allowsRunning(AISettings(enabled: true, providers: [claude])))
        #expect(!CopilotLifecycle.allowsRunning(AISettings(enabled: true, providers: [])))
    }

    @Test("Another active provider does not stop a configured Copilot")
    func anotherActiveProviderKeepsCopilot() {
        let settings = AISettings(enabled: true, providers: [copilot, claude], activeProviderID: claude.id)
        #expect(!CopilotLifecycle.shouldStop(settings, status: .running))
    }

    @Test("Turning AI off stops a running or retrying server")
    func aiOffStops() {
        let settings = AISettings(enabled: false, providers: [copilot], activeProviderID: copilot.id)
        #expect(CopilotLifecycle.shouldStop(settings, status: .running))
        #expect(CopilotLifecycle.shouldStop(settings, status: .starting))
        #expect(CopilotLifecycle.shouldStop(settings, status: .error("crashed")))
    }

    @Test("Removing the Copilot provider stops the server")
    func removingCopilotStops() {
        let settings = AISettings(enabled: true, providers: [claude], activeProviderID: claude.id)
        #expect(CopilotLifecycle.shouldStop(settings, status: .running))
    }

    @Test("A stopped server has nothing to stop")
    func stoppedIsLeftAlone() {
        #expect(!CopilotLifecycle.shouldStop(AISettings(enabled: false), status: .stopped))
    }
}

struct CopilotPriorExchangesTests {
    @Test("A first message carries no history")
    func firstMessageHasNoHistory() {
        let turns = [ChatTurnWire(role: .user, blocks: [.text("List the users")])]
        #expect(CopilotChatProvider.priorExchanges(in: turns).isEmpty)
    }

    @Test("A recreated conversation carries every earlier exchange, not the message being sent")
    func earlierExchangesArePaired() {
        let turns = [
            ChatTurnWire(role: .user, blocks: [.text("List the users")]),
            ChatTurnWire(role: .assistant, blocks: [.text("There are three.")]),
            ChatTurnWire(role: .user, blocks: [.text("Name them")]),
            ChatTurnWire(role: .assistant, blocks: [.text("Ann, Bo, Cy.")]),
            ChatTurnWire(role: .user, blocks: [.text("Count the admins")])
        ]
        let exchanges = CopilotChatProvider.priorExchanges(in: turns)
        #expect(exchanges.map(\.request) == ["List the users", "Name them"])
        #expect(exchanges.map(\.response) == ["There are three.", "Ann, Bo, Cy."])
    }

    @Test("An exchange with no answer keeps its request with an empty response")
    func unansweredExchangeIsKept() {
        let turns = [
            ChatTurnWire(role: .user, blocks: [.text("List the users")]),
            ChatTurnWire(role: .user, blocks: [.text("Count the admins")])
        ]
        let exchanges = CopilotChatProvider.priorExchanges(in: turns)
        #expect(exchanges.map(\.request) == ["List the users"])
        #expect(exchanges.map(\.response) == [""])
    }
}
