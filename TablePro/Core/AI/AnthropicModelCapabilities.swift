//
//  AnthropicModelCapabilities.swift
//  TablePro
//

import Foundation

enum AnthropicThinkingMode: String, Sendable, Equatable {
    case adaptive
    case budgeted
}

struct AnthropicModelCapabilities: Sendable, Equatable {
    static let minimumThinkingBudgetTokens = 1_024

    let thinkingMode: AnthropicThinkingMode
    let effortLevels: [ReasoningEffort]

    var sendsEffortParameter: Bool {
        thinkingMode == .adaptive
    }

    func clampedEffort(_ requested: ReasoningEffort) -> ReasoningEffort? {
        guard !effortLevels.isEmpty else { return nil }
        if effortLevels.contains(requested) { return requested }

        let ranking = ReasoningEffort.allCases
        guard let requestedRank = ranking.firstIndex(of: requested) else { return effortLevels.last }

        let atOrBelow = effortLevels.filter { level in
            guard let rank = ranking.firstIndex(of: level) else { return false }
            return rank <= requestedRank
        }
        return atOrBelow.last ?? effortLevels.first
    }

    static func resolve(model: String) -> AnthropicModelCapabilities {
        let normalized = model.lowercased().replacingOccurrences(of: ".", with: "-")
        for entry in table where entry.patterns.contains(where: { normalized.contains($0) }) {
            return entry.capabilities
        }
        return adaptive
    }

    static func effortLevels(forModel model: String) -> [ReasoningEffort] {
        resolve(model: model).effortLevels
    }

    private static let adaptive = AnthropicModelCapabilities(
        thinkingMode: .adaptive,
        effortLevels: [.low, .medium, .high, .xhigh]
    )

    private static let adaptiveWithoutExtraHigh = AnthropicModelCapabilities(
        thinkingMode: .adaptive,
        effortLevels: [.low, .medium, .high]
    )

    private static let budgeted = AnthropicModelCapabilities(
        thinkingMode: .budgeted,
        effortLevels: [.low, .medium, .high]
    )

    private struct Entry {
        let patterns: [String]
        let capabilities: AnthropicModelCapabilities
    }

    private static let table: [Entry] = [
        Entry(
            patterns: [
                "opus-4-5", "opus-4-1", "opus-4-0", "opus-4-2025",
                "sonnet-4-5", "sonnet-4-0", "sonnet-4-2025",
                "haiku-4-5",
                "claude-3"
            ],
            capabilities: budgeted
        ),
        Entry(
            patterns: ["opus-4-6", "sonnet-4-6"],
            capabilities: adaptiveWithoutExtraHigh
        ),
        Entry(
            patterns: [
                "opus-4-7", "opus-4-8", "opus-5",
                "sonnet-5", "haiku-5",
                "fable-5", "mythos-5"
            ],
            capabilities: adaptive
        )
    ]
}
