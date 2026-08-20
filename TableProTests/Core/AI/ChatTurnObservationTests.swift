//
//  ChatTurnObservationTests.swift
//  TableProTests
//

import Foundation
import Observation
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

        var messagesInvalidated = false
        withObservationTracking {
            _ = viewModel.messages.count
        } onChange: {
            messagesInvalidated = true
        }

        turn.appendStreamingToken("hello")

        #expect(messagesInvalidated == false)
        #expect(turn.plainText == "hello")
    }

    @Test("Appending a streaming token leaves the turn's block list untouched")
    func tokenAppendDoesNotInvalidateBlockList() {
        let (turn, _) = makeStreamingTurn()

        var blockListInvalidated = false
        withObservationTracking {
            _ = turn.blocks.count
        } onChange: {
            blockListInvalidated = true
        }

        turn.appendStreamingToken("hello")

        #expect(blockListInvalidated == false)
    }

    @Test("Appending a streaming token invalidates only the block that grew")
    func tokenAppendInvalidatesGrowingBlock() {
        let (turn, block) = makeStreamingTurn()

        var blockInvalidated = false
        withObservationTracking {
            _ = block.kind
        } onChange: {
            blockInvalidated = true
        }

        turn.appendStreamingToken("hello")

        #expect(blockInvalidated)
    }

    @Test("The message list's own reads survive a streaming token without invalidation")
    func panelLevelReadsSurviveStreamingToken() {
        let viewModel = AIChatViewModel()
        let (turn, _) = makeStreamingTurn()
        viewModel.messages.append(turn)
        viewModel.streamingState = .streaming(assistantID: turn.id)

        var panelInvalidated = false
        withObservationTracking {
            for message in viewModel.messages {
                _ = message.id
                _ = message.role
                if !viewModel.isStreaming {
                    _ = message.plainText
                }
            }
        } onChange: {
            panelInvalidated = true
        }

        turn.appendStreamingToken("hello")

        #expect(panelInvalidated == false)
    }

    @Test("Starting a new block invalidates the owning turn but not the messages array")
    func newBlockInvalidatesTurnOnly() {
        let viewModel = AIChatViewModel()
        let (turn, _) = makeStreamingTurn()
        viewModel.messages.append(turn)

        var messagesInvalidated = false
        withObservationTracking {
            _ = viewModel.messages.count
        } onChange: {
            messagesInvalidated = true
        }

        var blockListInvalidated = false
        withObservationTracking {
            _ = turn.blocks.count
        } onChange: {
            blockListInvalidated = true
        }

        turn.appendBlock(.toolUse(ToolUseBlock(id: "t1", name: "noop", input: .object([:]))))

        #expect(messagesInvalidated == false)
        #expect(blockListInvalidated)
    }

    @Test("Setting usage on one turn does not invalidate a sibling turn")
    func usageUpdateIsScopedToItsTurn() {
        let first = ChatTurn(role: .assistant, blocks: [ChatContentBlock.text("done")])
        let (second, _) = makeStreamingTurn()

        var siblingInvalidated = false
        withObservationTracking {
            _ = first.usage
        } onChange: {
            siblingInvalidated = true
        }

        second.usage = AITokenUsage(inputTokens: 10, outputTokens: 20)

        #expect(siblingInvalidated == false)
    }
}
