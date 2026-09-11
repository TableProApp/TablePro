//
//  MCPRemoteToolAdapter.swift
//  TablePro
//

import Foundation

/// One outside server's tool, offered to a session as an ordinary chat tool.
///
/// The name carries the server's id, not its display name: `ClaudeAgentProvider` launches the CLI
/// with `--allowedTools mcp__tablepro__*`, so a server the user called "TablePro" would otherwise
/// land inside a pre-approved wildcard and run with no card. A UUID cannot collide with that, and
/// `ChatToolRegistry.register` separately refuses any name a built-in already holds, so a remote
/// `execute_query` can never be reached as the built-in one.
///
/// `mode` is `.readOnly` so the tool is offered in every chat mode, and that is the only thing the
/// mode decides here: `computeInitialApprovalState` forces every remote call to wait for a human
/// regardless. "Read-only" is the server's claim about itself, which is not a claim TablePro can act
/// on.
internal struct MCPRemoteToolAdapter: ChatTool {
    internal let name: String
    internal let description: String
    internal let inputSchema: JsonValue
    internal let mode: ChatToolMode = .readOnly

    internal let serverId: UUID
    internal let serverName: String
    internal let remoteName: String

    /// How the call is made. Injected so the adapter can be tested without a server, and so a session
    /// ending can drop its transport without the registry entry having to know how one is built.
    private let invoke: @Sendable (String, JsonValue) async throws -> String

    internal init(
        server: MCPServerConfiguration,
        tool: MCPRemoteTool,
        invoke: @escaping @Sendable (String, JsonValue) async throws -> String
    ) {
        self.serverId = server.id
        self.serverName = server.name
        self.remoteName = tool.name
        self.name = server.toolName(for: tool.name)
        self.description = Self.describe(server: server, tool: tool)
        self.inputSchema = tool.inputSchema
        self.invoke = invoke
    }

    /// The server is named in the description so the model, and the approval card that shows it, both
    /// say where the call is going.
    private static func describe(server: MCPServerConfiguration, tool: MCPRemoteTool) -> String {
        let base = tool.description.isEmpty
            ? String(format: String(localized: "Tool %@ on the MCP server %@."), tool.name, server.name)
            : tool.description
        return String(
            format: String(localized: "%1$@ (runs on the outside MCP server %2$@)"),
            base,
            server.name
        )
    }

    /// The audit entry is written before the request leaves, not after it returns. A server that
    /// never answers has still been sent the arguments, and an entry written on completion would miss
    /// exactly the calls worth auditing.
    internal func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let payload = (try? JSONEncoder().encode(input)) ?? Data()
        MCPAuditLogger.logOutboundToolCall(
            serverId: serverId,
            serverName: serverName,
            sessionId: context.sessionId ?? UUID(),
            connectionId: context.connectionId,
            toolName: name,
            payload: payload
        )
        do {
            let text = try await invoke(remoteName, input)
            return ChatToolResult(content: text)
        } catch let error as MCPClientError {
            return ChatToolResult(content: error.localizedMessage, isError: true)
        } catch {
            return ChatToolResult(content: error.localizedDescription, isError: true)
        }
    }
}
