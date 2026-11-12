//
//  AIProviderPreset.swift
//  TablePro
//

import Foundation

// Stored as `.custom` plus an id: a new `AIProviderType` case fails to decode on older synced builds.
struct AIProviderPreset: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let endpoint: String
    let icon: BrandIcon
    let authStyle: AIProviderType.AuthStyle
    // A 403 for a wrong key would otherwise read as a server error, which the chat offers to retry.
    let rejectsBadKeyWithForbidden: Bool
    // Ranked: a new provider starts on the first.
    let curatedModels: [CuratedModel]
    let modelIDs: AIModelIDFilter
    // What every chat model here accepts when the server's model list says nothing about reasoning.
    let reasoning: AIReasoningSupport?

    init(
        id: String,
        displayName: String,
        endpoint: String,
        icon: BrandIcon,
        authStyle: AIProviderType.AuthStyle,
        rejectsBadKeyWithForbidden: Bool,
        curatedModels: [CuratedModel] = [],
        modelIDs: AIModelIDFilter = .all,
        reasoning: AIReasoningSupport? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.icon = icon
        self.authStyle = authStyle
        self.rejectsBadKeyWithForbidden = rejectsBadKeyWithForbidden
        self.curatedModels = curatedModels
        self.modelIDs = modelIDs
        self.reasoning = reasoning
    }

    static let requesty = AIProviderPreset(
        id: "requesty",
        displayName: "Requesty",
        endpoint: "https://router.requesty.ai",
        icon: BrandIcon(slug: "requesty", fallbackSystemImage: "arrow.triangle.branch"),
        authStyle: .apiKey,
        rejectsBadKeyWithForbidden: true
    )

    // No Off: without an effort Meta runs its default, max on Muse Wonder and Muse Ember.
    private static let museReasoning = AIReasoningSupport(
        mode: .effortOnly,
        effortLevels: [.minimal, .low, .medium, .high, .xhigh],
        defaultEffort: .high,
        isMandatory: true
    )

    static let meta = AIProviderPreset(
        id: "meta",
        displayName: "Meta",
        endpoint: "https://api.meta.ai",
        icon: BrandIcon(slug: "meta", fallbackSystemImage: "infinity.circle"),
        authStyle: .apiKey,
        rejectsBadKeyWithForbidden: false,
        curatedModels: [
            CuratedModel(id: "muse-spark-1.3", displayName: "Muse Spark 1.3"),
            CuratedModel(id: "muse-wonder-1.0", displayName: "Muse Wonder"),
            CuratedModel(id: "muse-ember-1.0", displayName: "Muse Ember")
        ],
        // Meta may train on what a contributor model is sent, so one is used only when typed under Other….
        modelIDs: AIModelIDFilter(
            families: ["muse-spark-", "muse-wonder-", "muse-ember-"],
            unlistedParts: ["-contributor"]
        ),
        reasoning: museReasoning
    )

    static let all: [AIProviderPreset] = [.requesty, .meta]

    static func preset(withID id: String?) -> AIProviderPreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    // A gateway in the vendor's place names its models its own way, so its list is kept whole.
    func modelIDFilter(forEndpoint endpoint: String) -> AIModelIDFilter {
        guard let host = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased(),
              host == URL(string: self.endpoint)?.host?.lowercased()
        else { return .all }
        return modelIDs
    }

    func reasoning(forModelID modelID: String) -> AIReasoningSupport? {
        guard let reasoning, modelIDs.isChatFamily(modelID) else { return nil }
        return reasoning
    }
}

// For a model list with no capability field, where chat models are told apart by their id.
struct AIModelIDFilter: Equatable, Sendable {
    let families: [String]
    let unlistedParts: [String]

    static let all = AIModelIDFilter(families: [], unlistedParts: [])

    func isChatFamily(_ modelID: String) -> Bool {
        families.isEmpty || families.contains { modelID.hasPrefix($0) }
    }

    func lists(_ modelID: String) -> Bool {
        isChatFamily(modelID) && !unlistedParts.contains { modelID.contains($0) }
    }
}
