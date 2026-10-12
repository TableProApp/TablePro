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
    /// Empty when the provider's model list does not say, which is most of them: a plain OpenAI
    /// list carries an id and nothing else.
    let modalities: Set<AIModality>
    let reasoning: AIReasoningSupport?
    let isDeprecated: Bool
    /// The model the provider itself starts a new chat on.
    let isProviderDefault: Bool

    init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        modalities: Set<AIModality> = [],
        reasoning: AIReasoningSupport? = nil,
        isDeprecated: Bool = false,
        isProviderDefault: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.modalities = modalities
        self.reasoning = reasoning
        self.isDeprecated = isDeprecated
        self.isProviderDefault = isProviderDefault
    }

    var label: String {
        guard let displayName, !displayName.isEmpty else { return id }
        return displayName
    }

    /// Nil when the provider did not state the model's modalities.
    var supportsImages: Bool? {
        modalities.isEmpty ? nil : modalities.contains(.image)
    }
}
