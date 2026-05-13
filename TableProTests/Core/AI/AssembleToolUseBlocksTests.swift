//
//  AssembleToolUseBlocksTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("AIChatViewModel.assembleToolUseBlocks")
struct AssembleToolUseBlocksTests {
    @Test("Empty inputs produce empty objects")
    func emptyInputs() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "list_tables"],
            inputs: ["call_1": ""]
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].id == "call_1")
        #expect(blocks[0].name == "list_tables")
        #expect(blocks[0].input == .object([:]))
    }

    @Test("Fragmented JSON across chunk boundaries reassembles correctly")
    func fragmentedJSON() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "describe_table"],
            inputs: ["call_1": #"{"table":"us"# + #"ers","schema":"public"}"#]
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].input == .object([
            "table": .string("users"),
            "schema": .string("public")
        ]))
    }

    @Test("Order is preserved across multiple tool calls")
    func ordering() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_2", "call_1"],
            names: ["call_1": "describe_table", "call_2": "list_tables"],
            inputs: ["call_1": #"{}"#, "call_2": #"{}"#]
        )
        #expect(blocks.count == 2)
        #expect(blocks[0].id == "call_2")
        #expect(blocks[0].name == "list_tables")
        #expect(blocks[1].id == "call_1")
        #expect(blocks[1].name == "describe_table")
    }

    @Test("Missing name in dictionary skips that entry")
    func missingName() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1", "call_2"],
            names: ["call_2": "list_tables"],
            inputs: ["call_1": #"{}"#, "call_2": #"{}"#]
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].id == "call_2")
    }

    @Test("Malformed JSON falls back to empty object")
    func malformedJSON() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "list_tables"],
            inputs: ["call_1": "{not json"]
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].input == .object([:]))
    }
}
