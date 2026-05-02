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
            MCPAuditLogger.logToolCalled(
                tokenId: nil,
                tokenName: context.principal.metadata.label,
                toolName: toolName,
                connectionId: Self.connectionId(in: arguments),
                outcome: .denied,
                errorMessage: "missing_scope"
            )
            throw MCPProtocolError.forbidden(reason: "Tool '\(toolName)' requires additional scopes")
        }

        Self.logger.info("tools/call name=\(toolName, privacy: .public)")

        do {
            let result = try await tool.call(arguments: arguments, context: context, services: services)
            MCPAuditLogger.logToolCalled(
                tokenId: nil,
                tokenName: context.principal.metadata.label,
                toolName: toolName,
                connectionId: Self.connectionId(in: arguments),
                outcome: result.isError ? .error : .success
            )
            return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result.asJsonValue())
        } catch {
            MCPAuditLogger.logToolCalled(
                tokenId: nil,
                tokenName: context.principal.metadata.label,
                toolName: toolName,
                connectionId: Self.connectionId(in: arguments),
                outcome: .error,
                errorMessage: (error as? MCPProtocolError)?.message ?? error.localizedDescription
            )
            throw error
        }
    }

    private static func connectionId(in arguments: JsonValue) -> UUID? {
        guard case .object(let object) = arguments,
              case .string(let value)? = object["connection_id"] else { return nil }
        return UUID(uuidString: value)
    }
}
