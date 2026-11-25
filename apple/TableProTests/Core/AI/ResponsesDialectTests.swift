//
//  ResponsesDialectTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ResponsesDialectTests {
    // Each provider names its own levels, so the wire value is the level itself; Off is OpenAI's `none`.
    @Test("An effort goes on the wire as the provider spells it")
    func wireValues() {
        #expect(ReasoningEffort.off.wireValue == "none")
        #expect(ReasoningEffort.xhigh.wireValue == "xhigh")
        #expect(ReasoningEffort.max.wireValue == "max")
        #expect(ReasoningEffort(wireValue: "none") == .off)
        #expect(ReasoningEffort(wireValue: "min") == nil, "Requesty spells it min and would get minimal back")
        #expect(ReasoningEffort(wireValue: "ultra") == nil)
    }

    @Test("A wire list keeps known levels in rank order, without Off or repeats")
    func levelsFromWire() {
        #expect(ReasoningEffort.levels(fromWire: ["max", "none", "low", "ultra", "low", "xhigh"]) == [.low, .xhigh, .max])
    }

    @Test("xAI's list carries each model's levels and default")
    func xaiLanguageModelReasoning() throws {
        let json: [String: Any] = [
            "id": "grok-4.5",
            "input_modalities": ["text", "image"],
            "output_modalities": ["text"],
            "capabilities": ["reasoning_effort": ["low", "medium", "high", "xhigh"], "default_reasoning_effort": "high"]
        ]
        let model = try #require(OpenAIResponsesProvider.decodeXAILanguageModel(json))
        #expect(model.reasoning?.effortLevels == [.low, .medium, .high, .xhigh])
        #expect(model.reasoning?.defaultEffort == .high)
        #expect(model.supportsImages == true)
    }
}
