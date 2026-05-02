import Foundation
import os

public struct PromptsGetHandler: MCPMethodHandler {
    public static let method = "prompts/get"
    public static let requiredScopes: Set<MCPScope> = []
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Prompts")

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        Self.logger.debug("prompts/get rejected: server has no prompts")
        throw MCPProtocolError.methodNotFound(method: "prompts/get")
    }
}
