//
//  ChatTurnInterleavingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ChatTurn streaming + block interleaving")
@MainActor
struct ChatTurnInterleavingTests {
    @Test("appendStreamingToken creates a streaming text block on first token")
    func firstTokenCreatesStreamingBlock() {
        var turn = ChatTurn(role: .assistant, blocks: [])
        turn.appendStreamingToken("Hello")

        #expect(turn.blocks.count == 1)
        if case .text(let text) = turn.blocks[0].kind {
            #expect(text == "Hello")
        } else {
            Issue.record("expected text block")
        }
        #expect(turn.blocks[0].isStreaming == true)
    }

    @Test("Successive tokens extend the same streaming text block")
    func tokensCoalesceIntoOneBlock() {
        var turn = ChatTurn(role: .assistant, blocks: [])
        turn.appendStreamingToken("Hello ")
        turn.appendStreamingToken("world")

        #expect(turn.blocks.count == 1)
        if case .text(let text) = turn.blocks[0].kind {
            #expect(text == "Hello world")
        } else {
            Issue.record("expected single text block")
        }
    }

    @Test("Appending a non-text block finalises the streaming text block first")
    func toolBlockAppendedAfterStreamingTextPreservesOrder() {
        var turn = ChatTurn(role: .assistant, blocks: [])
        turn.appendStreamingToken("I'll check the schema")
        turn.appendStreamingToken(" first.")
        let toolBlock = ChatContentBlock.toolUse(
            ToolUseBlock(id: "1", name: "list_tables", input: .object([:]))
        )
        turn.appendBlock(toolBlock)

        #expect(turn.blocks.count == 2)
        if case .text(let text) = turn.blocks[0].kind {
            #expect(text == "I'll check the schema first.")
        } else {
            Issue.record("expected text as first block")
        }
        #expect(turn.blocks[0].isStreaming == false)
        if case .toolUse = turn.blocks[1].kind {
            // ok
        } else {
            Issue.record("expected toolUse as second block")
        }
    }

    @Test("Multiple appended tool blocks land in order after the finalised text")
    func multipleToolBlocksKeepOrder() {
        var turn = ChatTurn(role: .assistant, blocks: [])
        turn.appendStreamingToken("Doing work")
        turn.appendBlock(.toolUse(ToolUseBlock(id: "a", name: "t1", input: .object([:]))))
        turn.appendBlock(.toolUse(ToolUseBlock(id: "b", name: "t2", input: .object([:]))))

        #expect(turn.blocks.count == 3)
        if case .toolUse(let one) = turn.blocks[1].kind { #expect(one.id == "a") }
        if case .toolUse(let two) = turn.blocks[2].kind { #expect(two.id == "b") }
    }

    @Test("Streaming token after a tool block starts a fresh streaming text block")
    func textAfterToolBlockOpensNewTextBlock() {
        var turn = ChatTurn(role: .assistant, blocks: [])
        turn.appendStreamingToken("First text")
        turn.appendBlock(.toolUse(ToolUseBlock(id: "a", name: "t", input: .object([:]))))
        turn.appendStreamingToken("Second text")

        #expect(turn.blocks.count == 3)
        if case .text(let last) = turn.blocks[2].kind {
            #expect(last == "Second text")
        } else {
            Issue.record("expected third block to be a fresh text block")
        }
        #expect(turn.blocks[2].isStreaming == true)
    }

    @Test("finishStreamingTextBlock marks the trailing streaming text as committed")
    func finishStreamingTextBlockMarksCommitted() {
        var turn = ChatTurn(role: .assistant, blocks: [])
        turn.appendStreamingToken("done")
        turn.finishStreamingTextBlock()

        #expect(turn.blocks.count == 1)
        #expect(turn.blocks[0].isStreaming == false)
    }

    @Test("wireSnapshot reflects current block order and content")
    func wireSnapshotPreservesOrder() {
        var turn = ChatTurn(role: .assistant, blocks: [])
        turn.appendStreamingToken("text")
        turn.appendBlock(.toolUse(ToolUseBlock(id: "1", name: "t", input: .object([:]))))

        let wire = turn.wireSnapshot
        #expect(wire.blocks.count == 2)
        if case .text(let value) = wire.blocks[0].kind { #expect(value == "text") }
        if case .toolUse(let value) = wire.blocks[1].kind { #expect(value.id == "1") }
    }

    @Test("ChatTurnWire round-trips through JSON Codable")
    func wireCodableRoundTrip() throws {
        let originalWire = ChatTurnWire(
            role: .assistant,
            blocks: [
                .text("hello"),
                .toolUse(ToolUseBlock(id: "1", name: "fn", input: .object([:])))
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(originalWire)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ChatTurnWire.self, from: data)

        #expect(restored.id == originalWire.id)
        #expect(restored.blocks.count == 2)
        if case .text(let value) = restored.blocks[0].kind { #expect(value == "hello") }
        if case .toolUse(let value) = restored.blocks[1].kind { #expect(value.id == "1") }
    }

    @Test("ChatTurn(wire:) reconstructs an observable turn with the same block ids")
    func roundTripPreservesBlockIDs() {
        let originalTurn = ChatTurn(role: .assistant, blocks: [
            .text("hi"),
            .toolUse(ToolUseBlock(id: "x", name: "fn", input: .object([:])))
        ])
        let restored = ChatTurn(wire: originalTurn.wireSnapshot)

        #expect(restored.blocks.count == originalTurn.blocks.count)
        for index in restored.blocks.indices {
            #expect(restored.blocks[index].id == originalTurn.blocks[index].id)
        }
    }
}
