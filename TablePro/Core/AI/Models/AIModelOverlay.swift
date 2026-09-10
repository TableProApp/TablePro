//
//  AIModelOverlay.swift
//  TablePro
//

import Foundation

enum AIModelOverlay {
    static func info(providerTypeID: String, modelID: String) -> AIModelInfo? {
        guard let type = AIProviderType(rawValue: providerTypeID) else { return nil }
        switch type {
        case .claude:
            return claudeInfo(modelID: modelID)
        case .openAI, .chatgptCodex:
            return openAIInfo(modelID: modelID)
        case .xai:
            return xaiInfo(modelID: modelID)
        default:
            return nil
        }
    }

    static func reasoning(providerTypeID: String, modelID: String) -> AIReasoningSupport? {
        info(providerTypeID: providerTypeID, modelID: modelID)?.reasoning
    }

    private static func claudeInfo(modelID: String) -> AIModelInfo {
        let capabilities = AnthropicModelCapabilities.resolve(model: modelID)
        return AIModelInfo(
            id: modelID,
            maxOutputTokens: nil,
            modalities: [.text, .image],
            reasoning: AIReasoningSupport(
                mode: capabilities.thinkingMode == .adaptive ? .adaptive : .budgeted,
                effortLevels: capabilities.effortLevels,
                defaultEffort: .medium
            )
        )
    }

    private static func openAIInfo(modelID: String) -> AIModelInfo? {
        let normalized = modelID.lowercased()
        guard let entry = openAITable.first(where: { entry in
            entry.patterns.contains { normalized.contains($0) }
        }) else { return nil }
        return AIModelInfo(
            id: modelID,
            maxOutputTokens: entry.maxOutputTokens,
            modalities: [.text, .image],
            reasoning: AIReasoningSupport(
                mode: .effortOnly,
                effortLevels: entry.effortLevels,
                defaultEffort: .medium
            )
        )
    }

    private static func xaiInfo(modelID: String) -> AIModelInfo? {
        let normalized = modelID.lowercased()
        guard normalized.contains("grok") else { return nil }
        if normalized.contains("non-reasoning") || normalized.contains("imagine") || normalized.contains("voice") {
            return AIModelInfo(id: modelID, modalities: [.text], reasoning: .unsupported)
        }
        return AIModelInfo(
            id: modelID,
            modalities: [.text, .image],
            reasoning: AIReasoningSupport(
                mode: .effortOnly,
                effortLevels: [.low, .medium, .high],
                defaultEffort: .medium
            )
        )
    }

    private struct OpenAIEntry {
        let patterns: [String]
        let effortLevels: [ReasoningEffort]
        let maxOutputTokens: Int?
    }

    private static let openAITable: [OpenAIEntry] = [
        OpenAIEntry(
            patterns: ["gpt-5.6", "gpt-5-6"],
            effortLevels: ReasoningEffort.allCases,
            maxOutputTokens: 128_000
        ),
        OpenAIEntry(
            patterns: ["gpt-5.5", "gpt-5-5"],
            effortLevels: [.low, .medium, .high, .xhigh],
            maxOutputTokens: 128_000
        ),
        OpenAIEntry(
            patterns: ["gpt-5.4", "gpt-5-4", "gpt-5.3", "gpt-5-3", "gpt-5.2", "gpt-5-2"],
            effortLevels: [.low, .medium, .high, .xhigh],
            maxOutputTokens: 128_000
        ),
        OpenAIEntry(
            patterns: ["codex"],
            effortLevels: [.low, .medium, .high],
            maxOutputTokens: 128_000
        ),
        OpenAIEntry(
            patterns: ["gpt-5"],
            effortLevels: [.low, .medium, .high],
            maxOutputTokens: 128_000
        )
    ]
}
