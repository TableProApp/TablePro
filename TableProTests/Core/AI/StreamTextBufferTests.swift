//
//  StreamTextBufferTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("StreamTextBuffer")
@MainActor
struct StreamTextBufferTests {
    @Test("Text appends accumulate and drain once")
    func textAccumulatesAndDrainsOnce() {
        let buffer = StreamTextBuffer()
        buffer.appendText("Hel")
        buffer.appendText("lo")

        #expect(buffer.hasBufferedText)
        #expect(buffer.drainText().text == "Hello")
        #expect(buffer.hasBufferedText == false)
        #expect(buffer.drainText().text.isEmpty)
    }

    @Test("Empty appends are ignored")
    func emptyAppendsAreIgnored() {
        let buffer = StreamTextBuffer()
        buffer.appendText("")

        #expect(buffer.hasBufferedText == false)
    }

    @Test("Usage survives until drained and counts as buffered content")
    func usageIsBufferedAndDrained() {
        let buffer = StreamTextBuffer()
        buffer.setUsage(AITokenUsage(inputTokens: 3, outputTokens: 7))

        #expect(buffer.hasBufferedText)
        let drained = buffer.drainText()
        #expect(drained.text.isEmpty)
        #expect(drained.usage?.outputTokens == 7)
        #expect(buffer.hasBufferedText == false)
    }

    @Test("Reasoning is kept per provider block and drained in arrival order")
    func reasoningIsGroupedInArrivalOrder() {
        let buffer = StreamTextBuffer()
        buffer.appendReasoning(providerBlockID: "b1", text: "one ")
        buffer.appendReasoning(providerBlockID: "b2", text: "two")
        buffer.appendReasoning(providerBlockID: "b1", text: "more")

        #expect(buffer.hasBufferedReasoning)
        let drained = buffer.drainReasoning()
        #expect(drained.map(\.providerBlockID) == ["b1", "b2"])
        #expect(drained.first?.text == "one more")
        #expect(buffer.hasBufferedReasoning == false)
    }

    @Test("Text and reasoning drain independently")
    func textAndReasoningAreIndependent() {
        let buffer = StreamTextBuffer()
        buffer.appendText("visible")
        buffer.appendReasoning(providerBlockID: "b1", text: "thinking")

        _ = buffer.drainText()

        #expect(buffer.hasBufferedReasoning)
        #expect(buffer.drainReasoning().first?.text == "thinking")
    }
}
