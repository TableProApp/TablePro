import Foundation
import os

public struct ToolsCallHandler: MCPMethodHandler {
    public static let method = "tools/call"
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    private let services: MCPToolServices

    public init(services: MCPToolServices) {
        self.services = services
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        guard case .object(let object)? = params else {
            throw MCPProtocolError.invalidParams(detail: "params must be object")
        }
        guard case .string(let toolName)? = object["name"] else {
            throw MCPProtocolError.invalidParams(detail: "missing tool name")
        }
        let arguments = object["arguments"] ?? .object([:])

        guard let tool = MCPToolRegistry.tool(named: toolName) else {
            throw MCPProtocolError.notFound(detail: "Unknown tool: \(toolName)")
        }

        let connectionId = Self.connectionId(in: arguments)
        let requiredScopes = type(of: tool).requiredScopes
        guard requiredScopes.isSubset(of: context.principal.scopes) else {
            Self.audit(
                context: context,
                tool: toolName,
                connectionId: connectionId,
                outcome: .denied,
                error: "missing_scope"
            )
            throw MCPProtocolError.insufficientScope(
                required: requiredScopes,
                reason: "Tool '\(toolName)' requires additional scopes"
            )
        }

        try await authorizeConnectionAccess(
            toolName: toolName,
            arguments: arguments,
            connectionId: connectionId,
            context: context
        )

        try await context.throwIfCancelled()
        Self.logger.info("tools/call name=\(toolName, privacy: .public)")

        do {
            let toolResult = try await tool.call(arguments: arguments, context: context, services: services)
            let result = try Self.result(from: toolResult)
            Self.audit(
                context: context,
                tool: toolName,
                connectionId: connectionId,
                outcome: toolResult.isError ? .error : .success
            )
            return result
        } catch {
            Self.audit(
                context: context,
                tool: toolName,
                connectionId: connectionId,
                outcome: .error,
                error: (error as? MCPProtocolError)?.message ?? error.localizedDescription
            )
            throw error
        }
    }

    private func authorizeConnectionAccess(
        toolName: String,
        arguments: JsonValue,
        connectionId: UUID?,
        context: MCPRequestContext
    ) async throws {
        do {
            try await services.authPolicy.resolveAndAuthorize(
                principal: context.principal,
                tool: toolName,
                connectionId: connectionId,
                sql: Self.sqlArgument(in: arguments)
            )
        } catch let error as MCPDataLayerError {
            Self.audit(
                context: context,
                tool: toolName,
                connectionId: connectionId,
                outcome: .denied,
                error: error.message
            )
            if case .forbidden(let reason, _) = error {
                throw MCPProtocolError.forbidden(reason: reason)
            }
            throw error
        }
    }

    private static func result(from toolResult: MCPToolCallResult) throws -> MCPResult {
        guard case .object(let fields) = toolResult.asJsonValue() else {
            throw MCPProtocolError.internalError(detail: "tool result was not a JSON object")
        }
        return .complete(fields)
    }

    private static func audit(
        context: MCPRequestContext,
        tool: String,
        connectionId: UUID?,
        outcome: AuditOutcome,
        error: String? = nil
    ) {
        MCPAuditLogger.logToolCalled(
            principal: context.principal,
            toolName: tool,
            connectionId: connectionId,
            outcome: outcome,
            errorMessage: error
        )
    }

    private static func connectionId(in arguments: JsonValue) -> UUID? {
        guard case .object(let object) = arguments,
              case .string(let value)? = object["connection_id"] else { return nil }
        return UUID(uuidString: value)
    }

    private static func sqlArgument(in arguments: JsonValue) -> String? {
        guard case .object(let object) = arguments,
              case .string(let value)? = object["query"] else { return nil }
        return value
    }
}
