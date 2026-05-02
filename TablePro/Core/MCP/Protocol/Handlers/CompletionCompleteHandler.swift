import Foundation
import os

public struct CompletionCompleteHandler: MCPMethodHandler {
    public static let method = "completion/complete"
    public static let requiredScopes: Set<MCPScope> = []
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Completion")

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        Self.logger.debug("completion/complete returning empty result")
        let result: JsonValue = .object([
            "completion": .object([
                "values": .array([]),
                "total": .int(0),
                "hasMore": .bool(false)
            ])
        ])
        return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
    }
}
