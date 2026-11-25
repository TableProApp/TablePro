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
    // The model always reasons and nothing turns it off, so sending no effort runs the server's default.
    let isMandatory: Bool
    // The model takes an explicit off (`none`, or Anthropic's `thinking: disabled`).
    let canTurnOff: Bool

    init(
        mode: AIReasoningMode,
        effortLevels: [ReasoningEffort],
        defaultEffort: ReasoningEffort? = nil,
        isMandatory: Bool = false,
        canTurnOff: Bool = false
    ) {
        self.mode = mode
        self.effortLevels = effortLevels.filter { $0 != .off }
        self.defaultEffort = defaultEffort == .off ? nil : defaultEffort
        self.isMandatory = isMandatory && !canTurnOff
        self.canTurnOff = canTurnOff
    }

    static let unsupported = AIReasoningSupport(mode: .unsupported, effortLevels: [])

    var sendsEffortParameter: Bool {
        mode != .unsupported && mode != .budgeted && !effortLevels.isEmpty
    }

    // A level picked for the model before any choice of the user's: the server's default, never above High.
    var preferredEffort: ReasoningEffort? {
        guard !effortLevels.isEmpty else { return nil }
        let wanted = defaultEffort.map { $0.rank > ReasoningEffort.high.rank ? .high : $0 } ?? .medium
        return clampedEffort(wanted)
    }

    func takes(_ effort: ReasoningEffort) -> Bool {
        effort == .off ? canTurnOff : effortLevels.contains(effort)
    }

    // nil means send nothing.
    func clampedEffort(_ requested: ReasoningEffort) -> ReasoningEffort? {
        if requested == .off {
            if canTurnOff { return .off }
            return isMandatory ? effortLevels.first : nil
        }
        guard !effortLevels.isEmpty else { return nil }
        if effortLevels.contains(requested) { return requested }
        let atOrBelow = effortLevels.filter { $0.rank <= requested.rank }
        return atOrBelow.last ?? effortLevels.first
    }
}

struct AIModelInfo: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String?
    let contextWindow: Int?
    let maxOutputTokens: Int?
    /// Empty when nothing says, which a plain OpenAI list never does.
    let modalities: Set<AIModality>
    let reasoning: AIReasoningSupport?
    let isDeprecated: Bool
    let retiresAt: Date?
    let released: Date?
    /// The model the provider itself starts a new chat on, or the one the catalog names for it.
    let isProviderDefault: Bool
    /// From the bundled catalog because the provider's own list could not be read.
    let isOffline: Bool

    init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        modalities: Set<AIModality> = [],
        reasoning: AIReasoningSupport? = nil,
        isDeprecated: Bool = false,
        retiresAt: Date? = nil,
        released: Date? = nil,
        isProviderDefault: Bool = false,
        isOffline: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.modalities = modalities
        self.reasoning = reasoning
        self.isDeprecated = isDeprecated
        self.retiresAt = retiresAt
        self.released = released
        self.isProviderDefault = isProviderDefault
        self.isOffline = isOffline
    }

    var label: String {
        guard let displayName, !displayName.isEmpty else { return id }
        return displayName
    }

    // Fine-tunes take their base model's name, so a name two models share carries the id.
    static func titles(for models: [AIModelInfo]) -> [String: String] {
        var counts: [String: Int] = [:]
        for model in models {
            counts[model.label, default: 0] += 1
        }
        var titles: [String: String] = [:]
        for model in models {
            titles[model.id] = counts[model.label, default: 0] > 1 && model.label != model.id
                ? "\(model.label) (\(model.id))"
                : model.label
        }
        return titles
    }

    /// Nil when the provider did not state the model's modalities.
    var supportsImages: Bool? {
        modalities.isEmpty ? nil : modalities.contains(.image)
    }
}
