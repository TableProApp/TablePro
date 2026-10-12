//
//  AIModels.swift
//  TablePro
//

import Foundation

// MARK: - AI Provider Type

enum AIProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case copilot
    case chatgptCodex
    case claude
    case claudeAgent
    case openAI
    case openRouter
    case gemini
    case xai
    case ollama
    case llamaCpp
    case mlx
    case openCode
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copilot:      return "GitHub Copilot"
        case .chatgptCodex: return "ChatGPT"
        case .claude:       return "Claude"
        case .claudeAgent:  return "Claude Agent"
        case .openAI:       return "OpenAI"
        case .openRouter:   return "OpenRouter"
        case .gemini:       return "Gemini"
        case .xai:          return "xAI"
        case .ollama:       return "Ollama"
        case .llamaCpp:     return "llama.cpp"
        case .mlx:          return "MLX"
        case .openCode:     return "OpenCode Zen"
        case .custom:       return String(localized: "Custom")
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .copilot:      return ""
        case .chatgptCodex: return ""
        case .claude:       return "https://api.anthropic.com"
        case .claudeAgent:  return ""
        case .openAI:       return "https://api.openai.com"
        case .openRouter:   return "https://openrouter.ai/api"
        case .gemini:       return "https://generativelanguage.googleapis.com"
        case .xai:          return "https://api.x.ai"
        case .ollama:       return "http://localhost:11434"
        case .llamaCpp:     return "http://localhost:8080"
        case .mlx:          return "http://localhost:8080"
        case .openCode:     return "https://opencode.ai/zen"
        case .custom:       return ""
        }
    }

    enum AuthStyle: Sendable {
        case apiKey, optionalApiKey, oauth, none

        var usesAPIKey: Bool { self == .apiKey || self == .optionalApiKey }
    }

    var authStyle: AuthStyle {
        switch self {
        case .copilot:      return .oauth
        case .chatgptCodex: return .oauth
        case .claude:       return .apiKey
        case .claudeAgent:  return .none
        case .openAI:       return .apiKey
        case .openRouter:   return .apiKey
        case .gemini:       return .apiKey
        case .xai:          return .apiKey
        case .ollama:       return .none
        case .llamaCpp:     return .none
        case .mlx:          return .none
        case .openCode:     return .optionalApiKey
        case .custom:       return .optionalApiKey
        }
    }

    /// How the configured endpoint is turned into a request URL. Providers that reach a fixed
    /// host ignore it, so they answer with `AIProviderFactory`'s own fallback transport.
    var endpointStyle: AIEndpointStyle {
        switch self {
        case .claude:
            return .messages
        case .openAI, .xai:
            return .responses
        case .gemini:
            return .gemini
        case .ollama:
            return .ollama
        case .copilot, .chatgptCodex, .claudeAgent, .openRouter, .llamaCpp, .mlx, .openCode, .custom:
            return .chatCompletions
        }
    }

    /// The types `OpenAICompatibleProvider` serves, which share one registration.
    static let openAICompatibleFamily: [AIProviderType] = [.openRouter, .openCode, .ollama, .llamaCpp, .mlx, .custom]

    var symbolName: String {
        switch self {
        case .copilot:      return "chevron.left.forwardslash.chevron.right"
        case .chatgptCodex: return "bubble.left.and.bubble.right"
        case .claude:       return "brain"
        case .claudeAgent:  return "terminal"
        case .openAI:       return "cpu"
        case .openRouter:   return "globe"
        case .gemini:       return "wand.and.stars"
        case .xai:          return "x.circle"
        case .ollama:       return "desktopcomputer"
        case .llamaCpp:     return "memorychip"
        case .mlx:          return "m.square"
        case .openCode:     return "sparkles"
        case .custom:       return "server.rack"
        }
    }
}

// MARK: - AI Provider Configuration

struct AIProviderConfig: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var type: AIProviderType
    /// Set on a `.custom` provider added from an `AIProviderPreset`. An id this build does not
    /// know is kept as it stands, so a preset from a newer build survives a round trip through
    /// this one and reads as a plain custom provider in the meantime.
    var presetID: String?
    var model: String
    var endpoint: String
    var maxOutputTokens: Int?
    var telemetryEnabled: Bool
    var reasoningEffort: ReasoningEffort?

    init(
        id: UUID = UUID(),
        name: String = "",
        type: AIProviderType = .claude,
        presetID: String? = nil,
        model: String = "",
        endpoint: String = "",
        maxOutputTokens: Int? = nil,
        telemetryEnabled: Bool = false,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.presetID = presetID
        self.model = model
        self.endpoint = endpoint.isEmpty ? Self.defaultEndpoint(type: type, presetID: presetID) : endpoint
        self.maxOutputTokens = maxOutputTokens
        self.telemetryEnabled = telemetryEnabled
        self.reasoningEffort = reasoningEffort
    }

    /// The name is stored rather than derived, so a build without this preset still lists the
    /// provider under the vendor's name.
    init(preset: AIProviderPreset) {
        self.init(name: preset.displayName, type: .custom, presetID: preset.id)
    }

    /// `id` and `type` are what make a row usable, so a row missing either one fails as a whole and
    /// `AISettings` drops it. Every other field falls back on its own.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(AIProviderType.self, forKey: .type)
        name = container.decodeSetting(.name, default: "")
        presetID = container.decodeSetting(.presetID)
        model = container.decodeSetting(.model, default: "")
        let rawEndpoint = container.decodeSetting(.endpoint, default: "")
        endpoint = rawEndpoint.isEmpty ? Self.defaultEndpoint(type: type, presetID: presetID) : rawEndpoint
        maxOutputTokens = container.decodeSetting(.maxOutputTokens)
        telemetryEnabled = container.decodeSetting(.telemetryEnabled, default: false)
        reasoningEffort = container.decodeSetting(.reasoningEffort)
    }

    var preset: AIProviderPreset? {
        guard type == .custom else { return nil }
        return AIProviderPreset.preset(withID: presetID)
    }

    /// What kind of provider this is, as opposed to what the user named it.
    var kindName: String { preset?.displayName ?? type.displayName }

    var displayName: String {
        name.isEmpty ? kindName : name
    }

    var symbolName: String { preset?.symbolName ?? type.symbolName }

    var authStyle: AIProviderType.AuthStyle { preset?.authStyle ?? type.authStyle }

    var defaultEndpoint: String { Self.defaultEndpoint(type: type, presetID: presetID) }

    private static func defaultEndpoint(type: AIProviderType, presetID: String?) -> String {
        guard type == .custom, let preset = AIProviderPreset.preset(withID: presetID) else {
            return type.defaultEndpoint
        }
        return preset.endpoint
    }
}

// MARK: - AI Connection Policy

enum AIConnectionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case alwaysAllow
    case askEachTime
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysAllow: return String(localized: "Always Allow")
        case .askEachTime: return String(localized: "Ask Each Time")
        case .never:       return String(localized: "Never")
        }
    }
}

// MARK: - AI Chat Mode

enum AIChatMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case edit
    case agent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask:   return String(localized: "Ask")
        case .edit:  return String(localized: "Edit")
        case .agent: return String(localized: "Agent")
        }
    }

    var symbolName: String {
        switch self {
        case .ask:   return "questionmark.bubble"
        case .edit:  return "pencil.and.outline"
        case .agent: return "infinity"
        }
    }

    var helpText: String {
        switch self {
        case .ask:
            return String(localized: "Ask: read-only schema lookups. AI can browse but not run queries.")
        case .edit:
            return String(localized: "Edit: read-only tools plus running queries. Destructive DDL stays blocked.")
        case .agent:
            return String(localized: "Agent: full tool access including destructive DDL. Safe mode still gates execution.")
        }
    }

    var systemPromptNote: String {
        switch self {
        case .ask:
            return "You are in Ask mode. Tools are read-only: schema lookups only. You cannot run queries or modify data."
        case .edit:
            return "You are in Edit mode. You can read schema and run SELECT/INSERT/UPDATE/DELETE via execute_query. Destructive DDL is blocked."
        case .agent:
            return "You are in Agent mode. All tools are available, including destructive DDL via confirm_destructive_operation. Safe mode policy still gates execution."
        }
    }
}

// MARK: - AI Settings

struct AISettings: Codable, Equatable, Sendable {
    var enabled: Bool
    var providers: [AIProviderConfig]
    var activeProviderID: UUID?
    var inlineSuggestionsEnabled: Bool
    var inlineSuggestionDebounceMs: Int
    var includeSchema: Bool
    var includeCurrentQuery: Bool
    var includeQueryResults: Bool
    var maxSchemaTables: Int
    var maxToolRoundtrips: Int
    var maxToolRoundtripsEnabled: Bool
    var defaultConnectionPolicy: AIConnectionPolicy
    var chatMode: AIChatMode
    /// Set from the composer's own context menu rather than the Settings window, because the only
    /// place the highlight is worth thinking about is the field it wraps.
    var composerHighlightEnabled: Bool

    static let defaultInlineSuggestionDebounceMs: Int = 500
    static let inlineSuggestionDebounceRange: ClosedRange<Int> = 100...3_000
    static let defaultMaxToolRoundtrips: Int = 25
    static let maxToolRoundtripsRange: ClosedRange<Int> = 5...200

    static let `default` = AISettings(
        enabled: true,
        providers: [],
        activeProviderID: nil,
        inlineSuggestionsEnabled: false,
        inlineSuggestionDebounceMs: AISettings.defaultInlineSuggestionDebounceMs,
        includeSchema: true,
        includeCurrentQuery: true,
        includeQueryResults: false,
        maxSchemaTables: 20,
        maxToolRoundtrips: AISettings.defaultMaxToolRoundtrips,
        maxToolRoundtripsEnabled: true,
        defaultConnectionPolicy: .askEachTime,
        chatMode: .ask,
        composerHighlightEnabled: true
    )

    init(
        enabled: Bool = true,
        providers: [AIProviderConfig] = [],
        activeProviderID: UUID? = nil,
        inlineSuggestionsEnabled: Bool = false,
        inlineSuggestionDebounceMs: Int = AISettings.defaultInlineSuggestionDebounceMs,
        includeSchema: Bool = true,
        includeCurrentQuery: Bool = true,
        includeQueryResults: Bool = false,
        maxSchemaTables: Int = 20,
        maxToolRoundtrips: Int = AISettings.defaultMaxToolRoundtrips,
        maxToolRoundtripsEnabled: Bool = true,
        defaultConnectionPolicy: AIConnectionPolicy = .askEachTime,
        chatMode: AIChatMode = .ask,
        composerHighlightEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.providers = providers
        self.activeProviderID = activeProviderID
        self.inlineSuggestionsEnabled = inlineSuggestionsEnabled
        self.inlineSuggestionDebounceMs = inlineSuggestionDebounceMs
        self.includeSchema = includeSchema
        self.includeCurrentQuery = includeCurrentQuery
        self.includeQueryResults = includeQueryResults
        self.maxSchemaTables = maxSchemaTables
        self.maxToolRoundtrips = maxToolRoundtrips
        self.maxToolRoundtripsEnabled = maxToolRoundtripsEnabled
        self.defaultConnectionPolicy = defaultConnectionPolicy
        self.chatMode = chatMode
        self.composerHighlightEnabled = composerHighlightEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        enabled = container.decodeSetting(.enabled, default: fallback.enabled)
        providers = container.decodeSettingElements(.providers)
        activeProviderID = container.decodeSetting(.activeProviderID)
        inlineSuggestionsEnabled = container.decodeSetting(.inlineSuggestionsEnabled, default: fallback.inlineSuggestionsEnabled)
        inlineSuggestionDebounceMs = container.decodeSetting(
            .inlineSuggestionDebounceMs, default: fallback.inlineSuggestionDebounceMs
        )
        includeSchema = container.decodeSetting(.includeSchema, default: fallback.includeSchema)
        includeCurrentQuery = container.decodeSetting(.includeCurrentQuery, default: fallback.includeCurrentQuery)
        includeQueryResults = container.decodeSetting(.includeQueryResults, default: fallback.includeQueryResults)
        maxSchemaTables = container.decodeSetting(.maxSchemaTables, default: fallback.maxSchemaTables)
        maxToolRoundtrips = container.decodeSetting(.maxToolRoundtrips, default: fallback.maxToolRoundtrips)
        maxToolRoundtripsEnabled = container.decodeSetting(.maxToolRoundtripsEnabled, default: fallback.maxToolRoundtripsEnabled)
        defaultConnectionPolicy = container.decodeSetting(.defaultConnectionPolicy, default: fallback.defaultConnectionPolicy)
        chatMode = container.decodeSetting(.chatMode, default: fallback.chatMode)
        composerHighlightEnabled = container.decodeSetting(.composerHighlightEnabled, default: fallback.composerHighlightEnabled)
    }

    var activeProvider: AIProviderConfig? {
        guard let activeProviderID else { return nil }
        return providers.first(where: { $0.id == activeProviderID })
    }

    var hasActiveProvider: Bool { activeProvider != nil }

    var hasCopilotConfigured: Bool {
        providers.contains(where: { $0.type == .copilot })
    }

    var clampedInlineSuggestionDebounceMs: Int {
        min(
            max(inlineSuggestionDebounceMs, AISettings.inlineSuggestionDebounceRange.lowerBound),
            AISettings.inlineSuggestionDebounceRange.upperBound
        )
    }

    var effectiveMaxToolRoundtrips: Int? {
        guard maxToolRoundtripsEnabled else { return nil }
        return min(
            max(maxToolRoundtrips, AISettings.maxToolRoundtripsRange.lowerBound),
            AISettings.maxToolRoundtripsRange.upperBound
        )
    }
}

struct AITokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens }
}
