//
//  AIChatTranscriptTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct AIChatTranscriptTests {
    private func turn(_ role: ChatRole, _ blocks: [ChatContentBlock] = [ChatContentBlock.text("body")]) -> ChatTurn {
        ChatTurn(role: role, blocks: blocks)
    }

    // MARK: - Rows

    @Test("A question that follows a reply gets room above it, and nothing else does")
    func onlyQuestionsAfterRepliesAreSpaced() {
        let firstUser = turn(.user)
        let firstAssistant = turn(.assistant)
        let secondUser = turn(.user)
        let thirdUser = turn(.user)

        let rows = ChatTranscriptRow.rows(for: [firstUser, firstAssistant, secondUser, thirdUser])

        #expect(rows.map(\.followsReply) == [false, false, true, false])
    }

    @Test("System turns and turns that only carry tool results are left out")
    func plumbingTurnsAreHidden() {
        let question = turn(.user)
        let reply = turn(.assistant)
        let toolResults = turn(.user, [ChatContentBlock.toolResult(ToolResultBlock(toolUseId: "1", content: "{}"))])
        let system = turn(.system)
        let followUp = turn(.user)

        let rows = ChatTranscriptRow.rows(for: [question, reply, toolResults, system, followUp])

        #expect(rows.map(\.id) == [question.id, reply.id, followUp.id])
        #expect(rows.last?.followsReply == true)
    }

    @Test("An empty conversation has no rows")
    func emptyConversation() {
        #expect(ChatTranscriptRow.rows(for: []).isEmpty)
    }

    // MARK: - Pinning

    private func edge(_ contentHeight: CGFloat, atBottom: Bool) -> ChatScrollEdge {
        ChatScrollEdge(contentHeight: contentHeight, isAtBottom: atBottom)
    }

    @Test("The first report only records where the end is")
    func firstReportKeepsThePin() {
        var pinning = ChatScrollPinning()
        #expect(pinning.update(with: edge(900, atBottom: false)) == false)
        #expect(pinning.isPinned)
    }

    @Test("A reply growing while the reader is at the end is followed")
    func growthAtTheEndIsFollowed() {
        var pinning = ChatScrollPinning()
        _ = pinning.update(with: edge(900, atBottom: true))
        #expect(pinning.update(with: edge(960, atBottom: false)) == true)
        #expect(pinning.isPinned)
    }

    @Test("Scrolling up unpins, and growth after that is not followed")
    func scrollingUpUnpins() {
        var pinning = ChatScrollPinning()
        _ = pinning.update(with: edge(900, atBottom: true))
        #expect(pinning.update(with: edge(900, atBottom: false)) == false)
        #expect(pinning.isPinned == false)
        #expect(pinning.update(with: edge(960, atBottom: false)) == false)
        #expect(pinning.isPinned == false)
    }

    @Test("Scrolling back to the end pins again")
    func returningToTheEndPins() {
        var pinning = ChatScrollPinning()
        _ = pinning.update(with: edge(900, atBottom: true))
        _ = pinning.update(with: edge(900, atBottom: false))
        _ = pinning.update(with: edge(900, atBottom: true))
        #expect(pinning.isPinned)
    }

    @Test("Pinning by hand follows the next growth again")
    func pinningByHandFollowsGrowth() {
        var pinning = ChatScrollPinning()
        _ = pinning.update(with: edge(900, atBottom: true))
        _ = pinning.update(with: edge(900, atBottom: false))
        pinning.pin()
        #expect(pinning.isPinned)
        #expect(pinning.update(with: edge(960, atBottom: false)) == true)
    }
}
