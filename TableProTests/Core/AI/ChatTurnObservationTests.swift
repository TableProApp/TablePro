//
//  ChatTurnObservationTests.swift
//  TableProTests
//

import Combine
import Foundation
import os
@testable import TablePro
import Testing

/// The granularity these assert is now `objectWillChange` per object rather than
/// `@Observable`'s per property: a mutation inside a block must not wake the turn or the
/// view model, or the whole chat re-renders on every streamed token.
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
        let observation = viewModel.objectWillChange.sink { _ in
            messagesInvalidated.withLock { $0 = true }
        }
        defer { observation.cancel() }

        turn.appendStreamingToken("hello")

        #expect(messagesInvalidated.withLock { $0 } == false)
        #expect(turn.plainText == "hello")
    }

    @Test("Appending a streaming token leaves the turn's block list untouched")
    func tokenAppendDoesNotInvalidateBlockList() {
        let (turn, _) = makeStreamingTurn()

        let blockListInvalidated = OSAllocatedUnfairLock(initialState: false)
        let observation = turn.objectWillChange.sink { _ in
            blockListInvalidated.withLock { $0 = true }
        }
        defer { observation.cancel() }

        turn.appendStreamingToken("hello")

        #expect(blockListInvalidated.withLock { $0 } == false)
    }

    @Test("Appending a streaming token invalidates only the block that grew")
    func tokenAppendInvalidatesGrowingBlock() {
        let (turn, block) = makeStreamingTurn()

        let blockInvalidated = OSAllocatedUnfairLock(initialState: false)
        let observation = block.objectWillChange.sink { _ in
            blockInvalidated.withLock { $0 = true }
        }
        defer { observation.cancel() }

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
        let observation = viewModel.objectWillChange.sink { _ in
            panelInvalidated.withLock { $0 = true }
        }
        defer { observation.cancel() }

        turn.appendStreamingToken("hello")

        #expect(panelInvalidated.withLock { $0 } == false)
    }

    @Test("Starting a new block invalidates the owning turn but not the messages array")
    func newBlockInvalidatesTurnOnly() {
        let viewModel = AIChatViewModel()
        let (turn, _) = makeStreamingTurn()
        viewModel.messages.append(turn)

        let messagesInvalidated = OSAllocatedUnfairLock(initialState: false)
        let messagesObservation = viewModel.objectWillChange.sink { _ in
            messagesInvalidated.withLock { $0 = true }
        }
        defer { messagesObservation.cancel() }

        let blockListInvalidated = OSAllocatedUnfairLock(initialState: false)
        let blockListObservation = turn.objectWillChange.sink { _ in
            blockListInvalidated.withLock { $0 = true }
        }
        defer { blockListObservation.cancel() }

        turn.appendBlock(.toolUse(ToolUseBlock(id: "t1", name: "noop", input: .object([:]))))

        #expect(messagesInvalidated.withLock { $0 } == false)
        #expect(blockListInvalidated.withLock { $0 })
    }

    @Test("Setting usage on one turn does not invalidate a sibling turn")
    func usageUpdateIsScopedToItsTurn() {
        let first = ChatTurn(role: .assistant, blocks: [ChatContentBlock.text("done")])
        let (second, _) = makeStreamingTurn()

        let siblingInvalidated = OSAllocatedUnfairLock(initialState: false)
        let observation = first.objectWillChange.sink { _ in
            siblingInvalidated.withLock { $0 = true }
        }
        defer { observation.cancel() }

        second.usage = AITokenUsage(inputTokens: 10, outputTokens: 20)

        #expect(siblingInvalidated.withLock { $0 } == false)
    }
}
