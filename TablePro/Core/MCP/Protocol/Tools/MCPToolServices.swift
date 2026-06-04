import Foundation

public struct MCPToolRuntimeSettings: Sendable, Equatable {
    public let defaultRowLimit: Int
    public let maxRowLimit: Int
    public let queryTimeoutSeconds: Int

    public static let `default` = MCPToolRuntimeSettings(
        defaultRowLimit: 500,
        maxRowLimit: 10_000,
        queryTimeoutSeconds: 30
    )

    public init(
        defaultRowLimit: Int,
        maxRowLimit: Int,
        queryTimeoutSeconds: Int
    ) {
        self.defaultRowLimit = defaultRowLimit
        self.maxRowLimit = maxRowLimit
        self.queryTimeoutSeconds = queryTimeoutSeconds
    }

    init(settings: MCPSettings) {
        self.defaultRowLimit = settings.defaultRowLimit
        self.maxRowLimit = settings.maxRowLimit
        self.queryTimeoutSeconds = settings.queryTimeoutSeconds
    }

    static func live() async -> MCPToolRuntimeSettings {
        await MainActor.run {
            MCPToolRuntimeSettings(settings: AppSettingsManager.shared.mcp)
        }
    }
}

public struct MCPToolServices: Sendable {
    public let connectionBridge: MCPConnectionBridge
    public let authPolicy: MCPAuthPolicy
    private let runtimeSettingsProvider: @Sendable () async -> MCPToolRuntimeSettings

    public init(connectionBridge: MCPConnectionBridge, authPolicy: MCPAuthPolicy) {
        self.init(
            connectionBridge: connectionBridge,
            authPolicy: authPolicy,
            runtimeSettingsProvider: { await MCPToolRuntimeSettings.live() }
        )
    }

    init(
        connectionBridge: MCPConnectionBridge,
        authPolicy: MCPAuthPolicy,
        runtimeSettingsProvider: @escaping @Sendable () async -> MCPToolRuntimeSettings
    ) {
        self.connectionBridge = connectionBridge
        self.authPolicy = authPolicy
        self.runtimeSettingsProvider = runtimeSettingsProvider
    }

    public func runtimeSettings() async -> MCPToolRuntimeSettings {
        await runtimeSettingsProvider()
    }
}
