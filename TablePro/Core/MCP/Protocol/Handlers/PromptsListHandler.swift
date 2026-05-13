import Foundation
import os

public struct PromptsListHandler: MCPMethodHandler {
    public static let method = "prompts/list"
    public static let requiredScopes: Set<MCPScope> = []
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Prompts")

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        Self.logger.debug("prompts/list returning empty list")
        let result: JsonValue = .object(["prompts": .array([])])
        return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
    }
}
