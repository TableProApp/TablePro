import Foundation
import os

public struct ToolsCallHandler: MCPMethodHandler {
    public static let method = "tools/call"
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    private let services: MCPToolServices

    public init(services: MCPToolServices) {
        self.services = services
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        guard case .object(let object)? = params else {
            throw MCPProtocolError.invalidParams(detail: "params must be object")
        }
        guard case .string(let toolName)? = object["name"] else {
            throw MCPProtocolError.invalidParams(detail: "missing tool name")
        }
        let arguments = object["arguments"] ?? .object([:])

        guard let tool = MCPToolRegistry.tool(named: toolName) else {
            throw MCPProtocolError.methodNotFound(method: "tools/call:\(toolName)")
        }

        let toolType = type(of: tool)
        if !toolType.requiredScopes.isSubset(of: context.principal.scopes) {
            throw MCPProtocolError.forbidden(reason: "Tool '\(toolName)' requires additional scopes")
        }

        Self.logger.info("tools/call name=\(toolName, privacy: .public)")

        let result = try await tool.call(arguments: arguments, context: context, services: services)
        return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result.asJsonValue())
    }
}
