import Foundation

public struct MCPToolServices: Sendable {
    public let connectionBridge: MCPConnectionBridge
    public let authPolicy: MCPAuthPolicy
    let settingsProvider: @Sendable () async -> MCPSettings
    let queryHistoryManager: QueryHistoryReading

    public init(connectionBridge: MCPConnectionBridge, authPolicy: MCPAuthPolicy) {
        self.init(
            connectionBridge: connectionBridge,
            authPolicy: authPolicy,
            settingsProvider: { await MainActor.run { AppSettingsManager.shared.mcp } }
        )
    }

    init(
        connectionBridge: MCPConnectionBridge,
        authPolicy: MCPAuthPolicy,
        settingsProvider: @escaping @Sendable () async -> MCPSettings,
        queryHistoryManager: QueryHistoryReading = QueryHistoryManager.shared
    ) {
        self.connectionBridge = connectionBridge
        self.authPolicy = authPolicy
        self.settingsProvider = settingsProvider
        self.queryHistoryManager = queryHistoryManager
    }
}
