//
//  AIModelInfo.swift
//  TablePro
//

import Foundation

enum AIModality: String, Codable, Sendable, CaseIterable {
    case text
    case image
}

enum AIReasoningMode: String, Codable, Sendable {
    case adaptive
    case budgeted
    case effortOnly
    case unsupported
}

struct AIReasoningSupport: Codable, Sendable, Equatable {
    let mode: AIReasoningMode
    let effortLevels: [ReasoningEffort]
    let defaultEffort: ReasoningEffort?
    let isMandatory: Bool

    init(
        mode: AIReasoningMode,
        effortLevels: [ReasoningEffort],
        defaultEffort: ReasoningEffort? = nil,
        isMandatory: Bool = false
    ) {
        self.mode = mode
        self.effortLevels = effortLevels
        self.defaultEffort = defaultEffort
        self.isMandatory = isMandatory
    }

    static let unsupported = AIReasoningSupport(mode: .unsupported, effortLevels: [])

    var sendsEffortParameter: Bool {
        mode != .unsupported && mode != .budgeted && !effortLevels.isEmpty
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
}

struct AIModelInfo: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String?
    let contextWindow: Int?
    let maxOutputTokens: Int?
    let modalities: Set<AIModality>
    let reasoning: AIReasoningSupport?
    let isDeprecated: Bool

    init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        modalities: Set<AIModality> = [.text],
        reasoning: AIReasoningSupport? = nil,
        isDeprecated: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.modalities = modalities
        self.reasoning = reasoning
        self.isDeprecated = isDeprecated
    }

    var label: String {
        guard let displayName, !displayName.isEmpty else { return id }
        return displayName
    }

    var supportsImages: Bool {
        modalities.contains(.image)
    }

    func merging(fallback: AIModelInfo?) -> AIModelInfo {
        guard let fallback else { return self }
        return AIModelInfo(
            id: id,
            displayName: displayName ?? fallback.displayName,
            contextWindow: contextWindow ?? fallback.contextWindow,
            maxOutputTokens: maxOutputTokens ?? fallback.maxOutputTokens,
            modalities: modalities.isEmpty ? fallback.modalities : modalities,
            reasoning: reasoning ?? fallback.reasoning,
            isDeprecated: isDeprecated || fallback.isDeprecated
        )
    }
}
