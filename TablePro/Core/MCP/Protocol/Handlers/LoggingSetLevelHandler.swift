import Foundation
import os

public struct LoggingSetLevelHandler: MCPMethodHandler {
    public static let method = "logging/setLevel"
    public static let requiredScopes: Set<MCPScope> = []
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Logging")

    public static let supportedLevels: Set<String> = [
        "debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"
    ]

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        guard case .string(let level)? = params?["level"] else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: level")
        }

        let normalized = level.lowercased()
        guard Self.supportedLevels.contains(normalized) else {
            throw MCPProtocolError.invalidParams(detail: "Unknown log level: \(level)")
        }

        Self.logger.notice("Client requested log level: \(normalized, privacy: .public)")
        return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: .object([:]))
    }
}
