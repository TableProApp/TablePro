//
//  SynthesizeResultsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AIChatViewModel.synthesizeResults")
struct SynthesizeResultsTests {
    private func block(_ id: String, _ approval: ToolApprovalState) -> ToolUseBlock {
        ToolUseBlock(id: id, name: "execute_query", input: .object([:]), approvalState: approval)
    }

    @Test("Every call gets an answer, in the order the calls were proposed")
    func everyCallIsAnswered() {
        let blocks = [block("call_0", .approved), block("call_1", .cancelled), block("call_2", .approved)]
        let executed = [
            ToolResultBlock(toolUseId: "call_0", content: "first", isError: false),
            ToolResultBlock(toolUseId: "call_2", content: "second", isError: false),
        ]

        let results = AIChatViewModel.synthesizeResults(for: blocks, executed: executed)

        #expect(results.count == 3)
        #expect(results[0].content == "first")
        #expect(results[1].isError)
        #expect(results[2].content == "second")
    }

    /// A provider is free to repeat a call id inside one round, and several number every turn's
    /// calls from `call_0`. Keying the executed results by id trapped on the duplicate.
    @Test("A repeated call id within one round does not trap")
    func repeatedIdsAreMatchedByPosition() {
        let blocks = [block("call_0", .approved), block("call_0", .approved)]
        let executed = [
            ToolResultBlock(toolUseId: "call_0", content: "first", isError: false),
            ToolResultBlock(toolUseId: "call_0", content: "second", isError: false),
        ]

        let results = AIChatViewModel.synthesizeResults(for: blocks, executed: executed)

        #expect(results.map(\.content) == ["first", "second"])
    }

    @Test("A denied call carries its reason back to the model")
    func deniedCallCarriesItsReason() {
        let blocks = [block("call_0", .denied(reason: "Safe Mode is read-only"))]

        let results = AIChatViewModel.synthesizeResults(for: blocks, executed: [])

        #expect(results.count == 1)
        #expect(results[0].content == "Safe Mode is read-only")
        #expect(results[0].isError)
    }

    @Test("An approved call with no result is reported rather than dropped")
    func missingResultIsReported() {
        let blocks = [block("call_0", .approved)]

        let results = AIChatViewModel.synthesizeResults(for: blocks, executed: [])

        #expect(results.count == 1)
        #expect(results[0].toolUseId == "call_0")
        #expect(results[0].isError)
    }
}
