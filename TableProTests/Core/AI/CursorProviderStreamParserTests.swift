//
//  CursorProviderStreamParserTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CursorProvider SSE stream parsing")
struct CursorProviderStreamParserTests {
    private func deltas(from lines: [String]) -> [CursorProvider.StreamParser.Output] {
        var parser = CursorProvider.StreamParser()
        return lines.compactMap { parser.consume($0) }
    }

    @Test("Assistant deltas are emitted in order, the consolidated result is skipped")
    func assistantDeltasEmittedResultSkipped() {
        let outputs = deltas(from: [
            "event: assistant",
            "data: {\"text\":\"SELECT \"}",
            "",
            "event: assistant",
            "data: {\"text\":\"1\"}",
            "",
            "event: result",
            "data: {\"text\":\"SELECT 1\"}",
            "",
            "event: done",
            "data: {}"
        ])
        #expect(outputs == [.text("SELECT "), .text("1"), .done])
    }

    @Test("When no assistant delta arrives, the result text is used as a fallback")
    func resultTextUsedWhenNoAssistantDelta() {
        let outputs = deltas(from: [
            "event: result",
            "data: {\"text\":\"SELECT 1\"}",
            "",
            "event: done",
            "data: {}"
        ])
        #expect(outputs == [.text("SELECT 1"), .done])
    }

    @Test("Event and blank lines produce no output")
    func eventAndBlankLinesProduceNothing() {
        var parser = CursorProvider.StreamParser()
        #expect(parser.consume("event: assistant") == nil)
        #expect(parser.consume("") == nil)
    }

    @Test("Empty assistant text is not emitted")
    func emptyAssistantTextSkipped() {
        let outputs = deltas(from: [
            "event: assistant",
            "data: {\"text\":\"\"}"
        ])
        #expect(outputs.isEmpty)
    }
}
