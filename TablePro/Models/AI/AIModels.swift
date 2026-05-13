//
//  AIModels.swift
//  TablePro
//
//  AI feature data models — provider configuration, chat messages, and settings.
//

import Foundation

// MARK: - AI Provider Type

enum AIProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case copilot
    case claude
    case openAI
    case openRouter
    case gemini
    case ollama
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copilot:    return "GitHub Copilot"
        case .claude:     return "Claude"
        case .openAI:     return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .gemini:     return "Gemini"
        case .ollama:     return "Ollama"
        case .custom:     return String(localized: "Custom")
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .copilot:    return ""
        case .claude:     return "https://api.anthropic.com"
        case .openAI:     return "https://api.openai.com"
        case .openRouter: return "https://openrouter.ai/api"
        case .gemini:     return "https://generativelanguage.googleapis.com"
        case .ollama:     return "http://localhost:11434"
        case .custom:     return ""
        }
    }

    enum AuthStyle: Sendable { case apiKey, oauth, none }

    var authStyle: AuthStyle {
        switch self {
        case .copilot: return .oauth
        case .ollama:  return .none
        default:       return .apiKey
        }
    }

    var symbolName: String {
        switch self {
        case .copilot:    return "chevron.left.forwardslash.chevron.right"
        case .claude:     return "brain"
        case .openAI:     return "cpu"
        case .openRouter: return "globe"
        case .gemini:     return "wand.and.stars"
        case .ollama:     return "desktopcomputer"
        case .custom:     return "server.rack"
        }
    }
}

// MARK: - AI Provider Configuration

struct AIProviderConfig: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var type: AIProviderType
    var model: String
    var endpoint: String
    var maxOutputTokens: Int?
    var telemetryEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        type: AIProviderType = .claude,
        model: String = "",
        endpoint: String = "",
        maxOutputTokens: Int? = nil,
        telemetryEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.model = model
        self.endpoint = endpoint.isEmpty ? type.defaultEndpoint : endpoint
        self.maxOutputTokens = maxOutputTokens
        self.telemetryEnabled = telemetryEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decode(AIProviderType.self, forKey: .type)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        let rawEndpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        endpoint = rawEndpoint.isEmpty ? type.defaultEndpoint : rawEndpoint
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        telemetryEnabled = try container.decodeIfPresent(Bool.self, forKey: .telemetryEnabled) ?? false
    }

    var displayName: String {
        name.isEmpty ? type.displayName : name
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
    var defaultConnectionPolicy: AIConnectionPolicy
    var chatMode: AIChatMode

    static let defaultInlineSuggestionDebounceMs: Int = 500
    static let inlineSuggestionDebounceRange: ClosedRange<Int> = 100...3_000

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
        defaultConnectionPolicy: .askEachTime,
        chatMode: .ask
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
        defaultConnectionPolicy: AIConnectionPolicy = .askEachTime,
        chatMode: AIChatMode = .ask
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
        self.defaultConnectionPolicy = defaultConnectionPolicy
        self.chatMode = chatMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        providers = try container.decodeIfPresent([AIProviderConfig].self, forKey: .providers) ?? []
        activeProviderID = try container.decodeIfPresent(UUID.self, forKey: .activeProviderID)
        inlineSuggestionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .inlineSuggestionsEnabled) ?? false
        inlineSuggestionDebounceMs = try container.decodeIfPresent(
            Int.self, forKey: .inlineSuggestionDebounceMs
        ) ?? AISettings.defaultInlineSuggestionDebounceMs
        includeSchema = try container.decodeIfPresent(Bool.self, forKey: .includeSchema) ?? true
        includeCurrentQuery = try container.decodeIfPresent(Bool.self, forKey: .includeCurrentQuery) ?? true
        includeQueryResults = try container.decodeIfPresent(Bool.self, forKey: .includeQueryResults) ?? false
        maxSchemaTables = try container.decodeIfPresent(Int.self, forKey: .maxSchemaTables) ?? 20
        defaultConnectionPolicy = try container.decodeIfPresent(
            AIConnectionPolicy.self, forKey: .defaultConnectionPolicy
        ) ?? .askEachTime
        chatMode = try container.decodeIfPresent(AIChatMode.self, forKey: .chatMode) ?? .ask
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
}

struct AITokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens }
}
