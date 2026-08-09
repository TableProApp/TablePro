//
//  AIChatMessageSpacingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AI chat message spacing")
@MainActor
struct AIChatMessageSpacingTests {
    private func turn(_ role: ChatRole) -> ChatTurn {
        ChatTurn(role: role, blocks: [ChatContentBlock.text("body")])
    }

    @Test("An empty message list produces no spacing and does not trap")
    func emptyListIsSafe() {
        #expect(AIChatMessageSpacing.spacedMessageIDs(for: []).isEmpty)
    }

    @Test("A single message produces no spacing")
    func singleMessageIsSafe() {
        #expect(AIChatMessageSpacing.spacedMessageIDs(for: [turn(.user)]).isEmpty)
    }

    @Test("A user message following an assistant message is spaced")
    func userAfterAssistantIsSpaced() {
        let assistant = turn(.assistant)
        let user = turn(.user)

        let spaced = AIChatMessageSpacing.spacedMessageIDs(for: [assistant, user])

        #expect(spaced == [user.id])
    }

    @Test("A user message following another user message is not spaced")
    func userAfterUserIsNotSpaced() {
        let first = turn(.user)
        let second = turn(.user)

        #expect(AIChatMessageSpacing.spacedMessageIDs(for: [first, second]).isEmpty)
    }

    @Test("Only the boundary messages in a longer conversation are spaced")
    func spacesEveryAssistantToUserBoundary() {
        let firstUser = turn(.user)
        let firstAssistant = turn(.assistant)
        let secondUser = turn(.user)
        let secondAssistant = turn(.assistant)
        let thirdUser = turn(.user)

        let spaced = AIChatMessageSpacing.spacedMessageIDs(
            for: [firstUser, firstAssistant, secondUser, secondAssistant, thirdUser]
        )

        #expect(spaced == [secondUser.id, thirdUser.id])
    }
}
