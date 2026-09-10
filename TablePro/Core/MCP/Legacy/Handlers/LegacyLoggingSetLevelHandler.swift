import Foundation
import os

public struct LegacyLoggingSetLevelHandler: MCPMethodHandler {
    public static let method = "logging/setLevel"
    public static let requiredScopes: Set<MCPScope> = []
    public static let isAvailableToModernClients = false
    public static let isAvailableToLegacyClients = true

    public static let supportedLevels: Set<String> = [
        "debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"
    ]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Legacy")

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        guard let level = params?["level"]?.stringValue else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: level")
        }

        let normalized = level.lowercased()
        guard Self.supportedLevels.contains(normalized) else {
            throw MCPProtocolError.invalidParams(detail: "Unknown log level: \(level)")
        }

        Self.logger.notice("Legacy client requested log level \(normalized, privacy: .public); TablePro logs to OSLog")
        return MCPResult.empty
    }
}
