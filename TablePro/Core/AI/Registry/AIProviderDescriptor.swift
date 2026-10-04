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

struct CuratedModel: Sendable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let supportedEffortLevels: [ReasoningEffort]
    let defaultEffort: ReasoningEffort?

    init(
        id: String,
        displayName: String,
        supportedEffortLevels: [ReasoningEffort] = [],
        defaultEffort: ReasoningEffort? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedEffortLevels = supportedEffortLevels
        self.defaultEffort = defaultEffort
    }
}

/// How a provider type behaves. Its name, icon and default endpoint live on `AIProviderType`.
struct AIProviderDescriptor: Sendable {
    let typeID: String
    let capabilities: AIProviderCapabilities
    let curatedModels: [CuratedModel]
    let showsTelemetryToggle: Bool
    let defaultTelemetryEnabled: Bool
    let oauthFlowKind: OAuthFlowKind?
    let effortLevelResolver: (@Sendable (String) -> [ReasoningEffort])?
    let makeProvider: @Sendable (AIProviderConfig, String?) -> ChatTransport

    var supportsReasoning: Bool { capabilities.contains(.reasoning) }
    var supportsImages: Bool { capabilities.contains(.images) }
    var allowsEndpointConfiguration: Bool { capabilities.contains(.endpointConfigurable) }
    var allowsNameConfiguration: Bool { capabilities.contains(.nameConfigurable) }
    var allowsMaxOutputTokens: Bool { capabilities.contains(.maxOutputTokens) }
    var fetchesModelList: Bool { capabilities.contains(.modelListFetchable) }

    func curatedModel(forID id: String) -> CuratedModel? {
        curatedModels.first(where: { $0.id == id })
    }

    /// `fetched` is what the provider's own model list said about the model, when it has been
    /// loaded. It wins over the offline tables, and its silence leaves the provider's envelope open.
    func supportedEffortLevels(forModelID id: String, fetched: AIModelInfo? = nil) -> [ReasoningEffort] {
        guard supportsReasoning else { return [] }
        if let reasoning = fetched?.reasoning ?? AIModelOverlay.reasoning(providerTypeID: typeID, modelID: id) {
            return reasoning.effortLevels
        }
        if let effortLevelResolver {
            return effortLevelResolver(id)
        }
        if let curated = curatedModel(forID: id), !curated.supportedEffortLevels.isEmpty {
            return curated.supportedEffortLevels
        }
        return [.low, .medium, .high]
    }

    func supportsImages(fetched: AIModelInfo?) -> Bool {
        guard supportsImages else { return false }
        return fetched?.supportsImages ?? true
    }

    init(
        typeID: String,
        capabilities: AIProviderCapabilities,
        curatedModels: [CuratedModel] = [],
        showsTelemetryToggle: Bool = false,
        defaultTelemetryEnabled: Bool = false,
        oauthFlowKind: OAuthFlowKind? = nil,
        effortLevelResolver: (@Sendable (String) -> [ReasoningEffort])? = nil,
        makeProvider: @escaping @Sendable (AIProviderConfig, String?) -> ChatTransport
    ) {
        self.typeID = typeID
        self.capabilities = capabilities
        self.curatedModels = curatedModels
        self.showsTelemetryToggle = showsTelemetryToggle
        self.defaultTelemetryEnabled = defaultTelemetryEnabled
        self.oauthFlowKind = oauthFlowKind
        self.effortLevelResolver = effortLevelResolver
        self.makeProvider = makeProvider
    }
}
