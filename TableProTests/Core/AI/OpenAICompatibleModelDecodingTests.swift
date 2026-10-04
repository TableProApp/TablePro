//
//  OpenAICompatibleModelDecodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct OpenAICompatibleModelDecodingTests {
    /// The shape of Requesty's /v1/models, trimmed to the fields that are read.
    private func requestyModel(vision: Bool, reasoning: Bool) -> [String: Any] {
        [
            "id": "zai/glm-5.3-flash",
            "object": "model",
            "max_output_tokens": 128_000,
            "context_window": 1_000_000,
            "supports_vision": vision,
            "supports_reasoning": reasoning,
            "supports_tool_calling": true
        ]
    }

    /// The shape of OpenRouter's /api/v1/models, trimmed the same way.
    private func openRouterModel(inputs: [String], parameters: [String]) -> [String: Any] {
        [
            "id": "inclusionai/ling-3.1-flash",
            "name": "inclusionAI: Ling 3.1 Flash",
            "context_length": 262_144,
            "architecture": ["input_modalities": inputs, "output_modalities": ["text"]],
            "top_provider": ["context_length": 262_144, "max_completion_tokens": 32_768],
            "supported_parameters": parameters
        ]
    }

    @Test("Requesty's flags decode into images and reasoning")
    func requestyShape() throws {
        let capable = try #require(OpenAICompatibleProvider.decodeModel(requestyModel(vision: true, reasoning: true)))
        #expect(capable.id == "zai/glm-5.3-flash")
        #expect(capable.supportsImages == true)
        #expect(capable.reasoning?.effortLevels == [.low, .medium, .high])
        #expect(capable.reasoning?.sendsEffortParameter == true)

        let plain = try #require(OpenAICompatibleProvider.decodeModel(requestyModel(vision: false, reasoning: false)))
        #expect(plain.supportsImages == false)
        #expect(plain.reasoning == .unsupported)
    }

    @Test("OpenRouter's architecture and supported parameters decode the same way")
    func openRouterShape() throws {
        let capable = try #require(
            OpenAICompatibleProvider.decodeModel(
                openRouterModel(inputs: ["text", "image"], parameters: ["max_tokens", "reasoning", "tools"])
            )
        )
        #expect(capable.supportsImages == true)
        #expect(capable.reasoning?.sendsEffortParameter == true)

        let plain = try #require(
            OpenAICompatibleProvider.decodeModel(openRouterModel(inputs: ["text"], parameters: ["max_tokens", "tools"]))
        )
        #expect(plain.supportsImages == false)
        #expect(plain.reasoning == .unsupported)
    }

    /// A plain OpenAI model list, and every local server, answers with an id and little else.
    @Test("A model with only an id claims nothing about images or reasoning")
    func plainShapeStaysUnknown() throws {
        let model = try #require(OpenAICompatibleProvider.decodeModel(["id": "glm-4.6", "object": "model"]))
        #expect(model.supportsImages == nil)
        #expect(model.reasoning == nil)
    }

    @Test("An entry with no usable id is skipped")
    func missingIDIsSkipped() {
        #expect(OpenAICompatibleProvider.decodeModel(["object": "model"]) == nil)
        #expect(OpenAICompatibleProvider.decodeModel(["id": ""]) == nil)
    }
}
