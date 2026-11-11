//
//  AssembleToolUseBlocksTests.swift
//  TableProTests
//

import Foundation
import TableProMCP
import TableProPluginKit
@testable import TablePro
import Testing

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

    @Test("Malformed JSON is denied with an explanation instead of running with empty arguments")
    func malformedJSON() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "list_tables"],
            inputs: ["call_1": "{not json"]
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].input == .object([:]))
        #expect(blocks[0].approvalState == .denied(reason: AIChatViewModel.unparsableToolArgumentsContent))
    }

    @Test("Arguments cut off at the output limit are denied, and the calls around them are not")
    func truncatedArguments() {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1", "call_2"],
            names: ["call_1": "execute_query", "call_2": "list_tables"],
            inputs: ["call_1": #"{"query":"SELECT * FROM orders WHERE"#, "call_2": #"{}"#]
        )
        #expect(blocks.count == 2)
        #expect(blocks[0].approvalState == .denied(reason: AIChatViewModel.unparsableToolArgumentsContent))
        #expect(blocks[1].approvalState == .approved)
        #expect(blocks[1].input == .object([:]))
    }

    @Test("Arguments that parse to something other than an object are denied", arguments: [#""users""#, "42", "[1]", "true"])
    func nonObjectArguments(raw: String) {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "describe_table"],
            inputs: ["call_1": raw]
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].approvalState == .denied(reason: AIChatViewModel.unparsableToolArgumentsContent))
    }

    @Test("A null or blank argument string reads as a call with no arguments", arguments: ["null", "  "])
    func nullArgumentsAreEmpty(raw: String) {
        let blocks = AIChatViewModel.assembleToolUseBlocks(
            order: ["call_1"],
            names: ["call_1": "list_tables"],
            inputs: ["call_1": raw]
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].input == .object([:]))
        #expect(blocks[0].approvalState == .approved)
    }
}
