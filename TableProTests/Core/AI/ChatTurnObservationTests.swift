//
//  ChatTurnObservationTests.swift
//  TableProTests
//

import Foundation
import Observation
import os
@testable import TablePro
import Testing

@Suite("ChatTurn observation granularity")
@MainActor
struct ChatTurnObservationTests {
    private func makeStreamingTurn() -> (ChatTurn, ChatContentBlock) {
        let block = ChatContentBlock.text("", isStreaming: true)
        return (ChatTurn(role: .assistant, blocks: [block]), block)
    }

    @Test("Appending a streaming token leaves the messages array untouched")
    func tokenAppendDoesNotInvalidateMessagesArray() {
        let viewModel = AIChatViewModel()
        let (turn, _) = makeStreamingTurn()
        viewModel.messages.append(turn)

        let messagesInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = viewModel.messages.count
        } onChange: {
            messagesInvalidated.withLock { $0 = true }
        }

        turn.appendStreamingToken("hello")

        #expect(messagesInvalidated.withLock { $0 } == false)
        #expect(turn.plainText == "hello")
    }

    @Test("Appending a streaming token leaves the turn's block list untouched")
    func tokenAppendDoesNotInvalidateBlockList() {
        let (turn, _) = makeStreamingTurn()

        let blockListInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = turn.blocks.count
        } onChange: {
            blockListInvalidated.withLock { $0 = true }
        }

        turn.appendStreamingToken("hello")

        #expect(blockListInvalidated.withLock { $0 } == false)
    }

    @Test("Appending a streaming token invalidates only the block that grew")
    func tokenAppendInvalidatesGrowingBlock() {
        let (turn, block) = makeStreamingTurn()

        let blockInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = block.kind
        } onChange: {
            blockInvalidated.withLock { $0 = true }
        }

        turn.appendStreamingToken("hello")

        #expect(blockInvalidated.withLock { $0 })
    }

    @Test("The message list's own reads survive a streaming token without invalidation")
    func panelLevelReadsSurviveStreamingToken() {
        let viewModel = AIChatViewModel()
        let (turn, _) = makeStreamingTurn()
        viewModel.messages.append(turn)
        viewModel.streamingState = .streaming(assistantID: turn.id)

        let panelInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            for message in viewModel.messages {
                _ = message.id
                _ = message.role
                if !viewModel.isStreaming {
                    _ = message.plainText
                }
            }
        } onChange: {
            panelInvalidated.withLock { $0 = true }
        }

        turn.appendStreamingToken("hello")

        #expect(panelInvalidated.withLock { $0 } == false)
    }

    @Test("Starting a new block invalidates the owning turn but not the messages array")
    func newBlockInvalidatesTurnOnly() {
        let viewModel = AIChatViewModel()
        let (turn, _) = makeStreamingTurn()
        viewModel.messages.append(turn)

        let messagesInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = viewModel.messages.count
        } onChange: {
            messagesInvalidated.withLock { $0 = true }
        }

        let blockListInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = turn.blocks.count
        } onChange: {
            blockListInvalidated.withLock { $0 = true }
        }

        turn.appendBlock(.toolUse(ToolUseBlock(id: "t1", name: "noop", input: .object([:]))))

        #expect(messagesInvalidated.withLock { $0 } == false)
        #expect(blockListInvalidated.withLock { $0 })
    }

    @Test("Setting usage on one turn does not invalidate a sibling turn")
    func usageUpdateIsScopedToItsTurn() {
        let first = ChatTurn(role: .assistant, blocks: [ChatContentBlock.text("done")])
        let (second, _) = makeStreamingTurn()

        let siblingInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = first.usage
        } onChange: {
            siblingInvalidated.withLock { $0 = true }
        }

        second.usage = AITokenUsage(inputTokens: 10, outputTokens: 20)

        #expect(siblingInvalidated.withLock { $0 } == false)
    }
}
