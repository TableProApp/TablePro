//
//  AIModels.swift
//  TablePro
//
//  AI feature data models - provider configuration, chat messages, and settings.
//

import Foundation

// MARK: - AI Provider Type

/// Supported AI provider types
enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case claude = "claude"
    case openAI = "openAI"
    case openRouter = "openRouter"
    case ollama = "ollama"
    case gemini = "gemini"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .gemini: return "Gemini"
        case .custom: return String(localized: "Custom")
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .claude: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com"
        case .openRouter: return "https://openrouter.ai/api"
        case .ollama: return "http://localhost:11434"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .custom: return ""
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        default: return true
        }
    }
}

// MARK: - AI Provider Configuration

/// Configuration for a single AI provider
struct AIProviderConfig: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var type: AIProviderType
    var model: String
    var endpoint: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        type: AIProviderType = .claude,
        model: String = "",
        endpoint: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.model = model
        self.endpoint = endpoint.isEmpty ? type.defaultEndpoint : endpoint
        self.isEnabled = isEnabled
    }
}

// MARK: - AI Feature

/// AI features that can be routed to specific providers
enum AIFeature: String, Codable, CaseIterable, Identifiable {
    case chat = "chat"
    case explainQuery = "explainQuery"
    case optimizeQuery = "optimizeQuery"
    case fixError = "fixError"
    case inlineSuggest = "inlineSuggest"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat: return String(localized: "Chat")
        case .explainQuery: return String(localized: "Explain Query")
        case .optimizeQuery: return String(localized: "Optimize Query")
        case .fixError: return String(localized: "Fix Error")
        case .inlineSuggest: return String(localized: "Inline Suggestions")
        }
    }
}

// MARK: - AI Feature Route

/// Routes an AI feature to a specific provider and model
struct AIFeatureRoute: Codable, Equatable {
    var providerID: UUID
    var model: String
}

// MARK: - AI Connection Policy

/// Per-connection AI data sharing policy
enum AIConnectionPolicy: String, Codable, CaseIterable, Identifiable {
    case alwaysAllow = "alwaysAllow"
    case askEachTime = "askEachTime"
    case never = "never"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysAllow: return String(localized: "Always Allow")
        case .askEachTime: return String(localized: "Ask Each Time")
        case .never: return String(localized: "Never")
        }
    }
}

// MARK: - AI Settings

/// Global AI feature settings
struct AISettings: Codable, Equatable {
    var providers: [AIProviderConfig]
    var featureRouting: [String: AIFeatureRoute]
    var includeSchema: Bool
    var includeCurrentQuery: Bool
    var includeQueryResults: Bool
    var maxSchemaTables: Int
    var defaultConnectionPolicy: AIConnectionPolicy
    var inlineSuggestEnabled: Bool

    static let `default` = AISettings(
        providers: [],
        featureRouting: [:],
        includeSchema: true,
        includeCurrentQuery: true,
        includeQueryResults: false,
        maxSchemaTables: 20,
        defaultConnectionPolicy: .askEachTime,
        inlineSuggestEnabled: false
    )

    init(
        providers: [AIProviderConfig] = [],
        featureRouting: [String: AIFeatureRoute] = [:],
        includeSchema: Bool = true,
        includeCurrentQuery: Bool = true,
        includeQueryResults: Bool = false,
        maxSchemaTables: Int = 20,
        defaultConnectionPolicy: AIConnectionPolicy = .askEachTime,
        inlineSuggestEnabled: Bool = false
    ) {
        self.providers = providers
        self.featureRouting = featureRouting
        self.includeSchema = includeSchema
        self.includeCurrentQuery = includeCurrentQuery
        self.includeQueryResults = includeQueryResults
        self.maxSchemaTables = maxSchemaTables
        self.defaultConnectionPolicy = defaultConnectionPolicy
        self.inlineSuggestEnabled = inlineSuggestEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([AIProviderConfig].self, forKey: .providers) ?? []
        featureRouting = try container.decodeIfPresent([String: AIFeatureRoute].self, forKey: .featureRouting) ?? [:]
        includeSchema = try container.decodeIfPresent(Bool.self, forKey: .includeSchema) ?? true
        includeCurrentQuery = try container.decodeIfPresent(Bool.self, forKey: .includeCurrentQuery) ?? true
        includeQueryResults = try container.decodeIfPresent(Bool.self, forKey: .includeQueryResults) ?? false
        maxSchemaTables = try container.decodeIfPresent(Int.self, forKey: .maxSchemaTables) ?? 20
        defaultConnectionPolicy = try container.decodeIfPresent(
            AIConnectionPolicy.self, forKey: .defaultConnectionPolicy
        ) ?? .askEachTime
        inlineSuggestEnabled = try container.decodeIfPresent(Bool.self, forKey: .inlineSuggestEnabled) ?? false
    }
}

// MARK: - AI Chat Message

/// A single message in an AI chat conversation
struct AIChatMessage: Codable, Equatable, Identifiable {
    let id: UUID
    var role: AIChatRole
    var content: String
    let timestamp: Date
    var usage: AITokenUsage?

    init(
        id: UUID = UUID(),
        role: AIChatRole,
        content: String,
        timestamp: Date = Date(),
        usage: AITokenUsage? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.usage = usage
    }
}

// MARK: - AI Chat Role

/// Role of a chat message participant
enum AIChatRole: String, Codable {
    case user
    case assistant
    case system
}

// MARK: - AI Token Usage

/// Token usage statistics from an AI response
struct AITokenUsage: Codable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens }
}

// MARK: - AI Stream Event

/// Events emitted during AI response streaming
enum AIStreamEvent {
    case text(String)
    case usage(AITokenUsage)
}
