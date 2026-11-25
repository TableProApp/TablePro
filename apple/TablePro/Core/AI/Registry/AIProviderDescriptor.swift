//
//  AIProviderDescriptor.swift
//  TablePro
//

import Foundation

struct AIProviderCapabilities: OptionSet, Sendable {
    let rawValue: UInt16

    static let reasoning = AIProviderCapabilities(rawValue: 1 << 0)
    static let images = AIProviderCapabilities(rawValue: 1 << 1)
    static let endpointConfigurable = AIProviderCapabilities(rawValue: 1 << 2)
    static let nameConfigurable = AIProviderCapabilities(rawValue: 1 << 3)
    static let maxOutputTokens = AIProviderCapabilities(rawValue: 1 << 4)
    static let modelListFetchable = AIProviderCapabilities(rawValue: 1 << 5)
}

/// How a provider type behaves. Its name, icon and default endpoint live on `AIProviderType`.
struct AIProviderDescriptor: Sendable {
    let typeID: String
    let capabilities: AIProviderCapabilities
    let showsTelemetryToggle: Bool
    let defaultTelemetryEnabled: Bool
    let oauthFlowKind: OAuthFlowKind?
    // What a model nothing describes takes: the `reasoning_effort` an OpenAI-compatible server reads, else nothing.
    let unknownReasoning: AIReasoningSupport?
    let makeProvider: @Sendable (AIProviderConfig, String?) -> ChatTransport

    var supportsReasoning: Bool { capabilities.contains(.reasoning) }
    var supportsImages: Bool { capabilities.contains(.images) }
    var allowsEndpointConfiguration: Bool { capabilities.contains(.endpointConfigurable) }
    var allowsNameConfiguration: Bool { capabilities.contains(.nameConfigurable) }
    var allowsMaxOutputTokens: Bool { capabilities.contains(.maxOutputTokens) }
    var fetchesModelList: Bool { capabilities.contains(.modelListFetchable) }

    // `info` is the provider's list merged with the catalog; with nothing known no level is guessed.
    func reasoning(for info: AIModelInfo?) -> AIReasoningSupport {
        guard supportsReasoning else { return .unsupported }
        return info?.reasoning ?? unknownReasoning ?? .unsupported
    }

    func supportedEffortLevels(for info: AIModelInfo?) -> [ReasoningEffort] {
        reasoning(for: info).effortLevels
    }

    // The saved effort belongs to the saved model, and the chat panel can send another one. nil sends nothing.
    func effort(_ requested: ReasoningEffort?, for info: AIModelInfo?) -> ReasoningEffort? {
        let reasoning = reasoning(for: info)
        guard let requested else {
            return reasoning.isMandatory ? reasoning.preferredEffort : nil
        }
        return reasoning.clampedEffort(requested)
    }

    func supportsImages(fetched: AIModelInfo?) -> Bool {
        guard supportsImages else { return false }
        return fetched?.supportsImages ?? true
    }

    init(
        typeID: String,
        capabilities: AIProviderCapabilities,
        showsTelemetryToggle: Bool = false,
        defaultTelemetryEnabled: Bool = false,
        oauthFlowKind: OAuthFlowKind? = nil,
        unknownReasoning: AIReasoningSupport? = nil,
        makeProvider: @escaping @Sendable (AIProviderConfig, String?) -> ChatTransport
    ) {
        self.typeID = typeID
        self.capabilities = capabilities
        self.showsTelemetryToggle = showsTelemetryToggle
        self.defaultTelemetryEnabled = defaultTelemetryEnabled
        self.oauthFlowKind = oauthFlowKind
        self.unknownReasoning = unknownReasoning
        self.makeProvider = makeProvider
    }
}
