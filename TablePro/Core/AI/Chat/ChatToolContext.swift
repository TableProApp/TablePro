//
//  ChatToolContext.swift
//  TablePro
//

import Foundation

/// Per-call context passed to `ChatTool.execute(input:context:)`. Carries the
/// active chat connection (so tools can default `connection_id` arguments),
/// the shared `MCPConnectionBridge` actor that does the underlying database
/// work, and the `MCPAuthPolicy` that gates write/destructive queries through
/// the connection's safe-mode dialog.
struct ChatToolContext: Sendable {
    let connectionId: UUID?
    let bridge: MCPConnectionBridge
    let authPolicy: MCPAuthPolicy
    private let runtimeSettingsProvider: @Sendable () async -> MCPToolRuntimeSettings

    init(
        connectionId: UUID?,
        bridge: MCPConnectionBridge,
        authPolicy: MCPAuthPolicy,
        runtimeSettingsProvider: @escaping @Sendable () async -> MCPToolRuntimeSettings = {
            await MCPToolRuntimeSettings.live()
        }
    ) {
        self.connectionId = connectionId
        self.bridge = bridge
        self.authPolicy = authPolicy
        self.runtimeSettingsProvider = runtimeSettingsProvider
    }

    func runtimeSettings() async -> MCPToolRuntimeSettings {
        await runtimeSettingsProvider()
    }
}
