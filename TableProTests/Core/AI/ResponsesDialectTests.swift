//
//  ResponsesDialectTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ResponsesDialect")
struct ResponsesDialectTests {
    @Test("Each dialect has its own default test model")
    func defaultTestModels() {
        #expect(ResponsesDialect.openAI.defaultTestModel == "gpt-5.5")
        #expect(ResponsesDialect.xai.defaultTestModel == "grok-4.5")
    }

    @Test("xAI reasoning effort clamps to the low/medium/high set the API accepts")
    func effortMapping() {
        #expect(ReasoningEffort.minimal.xaiReasoningEffort == "low")
        #expect(ReasoningEffort.low.xaiReasoningEffort == "low")
        #expect(ReasoningEffort.medium.xaiReasoningEffort == "medium")
        #expect(ReasoningEffort.high.xaiReasoningEffort == "high")
        #expect(ReasoningEffort.xhigh.xaiReasoningEffort == "high")
    }
}
