//
//  AIProviderDescriptor.swift
//  TablePro
//

import Foundation

struct AIProviderCapabilities: OptionSet, Sendable {
    let rawValue: UInt16

    static let chat = AIProviderCapabilities(rawValue: 1 << 0)
    static let inline = AIProviderCapabilities(rawValue: 1 << 1)
    static let models = AIProviderCapabilities(rawValue: 1 << 2)
    static let reasoning = AIProviderCapabilities(rawValue: 1 << 3)
    static let images = AIProviderCapabilities(rawValue: 1 << 4)
    static let endpointConfigurable = AIProviderCapabilities(rawValue: 1 << 5)
    static let nameConfigurable = AIProviderCapabilities(rawValue: 1 << 6)
    static let maxOutputTokens = AIProviderCapabilities(rawValue: 1 << 7)
    static let modelListFetchable = AIProviderCapabilities(rawValue: 1 << 8)
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

struct AIProviderDescriptor: Sendable {
    let typeID: String
    let displayName: String
    let defaultEndpoint: String
    let requiresAPIKey: Bool
    let capabilities: AIProviderCapabilities
    let symbolName: String
    let curatedModels: [CuratedModel]
    let showsTelemetryToggle: Bool
    let defaultTelemetryEnabled: Bool
    let oauthFlowKind: OAuthFlowKind?
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

    func supportedEffortLevels(forModelID id: String) -> [ReasoningEffort] {
        guard supportsReasoning else { return [] }
        if let curated = curatedModel(forID: id), !curated.supportedEffortLevels.isEmpty {
            return curated.supportedEffortLevels
        }
        return [.low, .medium, .high]
    }

    init(
        typeID: String,
        displayName: String,
        defaultEndpoint: String,
        requiresAPIKey: Bool,
        capabilities: AIProviderCapabilities,
        symbolName: String,
        curatedModels: [CuratedModel] = [],
        showsTelemetryToggle: Bool = false,
        defaultTelemetryEnabled: Bool = false,
        oauthFlowKind: OAuthFlowKind? = nil,
        makeProvider: @escaping @Sendable (AIProviderConfig, String?) -> ChatTransport
    ) {
        self.typeID = typeID
        self.displayName = displayName
        self.defaultEndpoint = defaultEndpoint
        self.requiresAPIKey = requiresAPIKey
        self.capabilities = capabilities
        self.symbolName = symbolName
        self.curatedModels = curatedModels
        self.showsTelemetryToggle = showsTelemetryToggle
        self.defaultTelemetryEnabled = defaultTelemetryEnabled
        self.oauthFlowKind = oauthFlowKind
        self.makeProvider = makeProvider
    }
}
