import Foundation
import os

final class MCPRouter: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPRouter")

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    enum RouteResult: Sendable {
        case json(Data, sessionId: String?)
        case sseStream(sessionId: String)
        case accepted
        case noContent
        case httpError(status: Int, message: String)
        case httpErrorWithHeaders(status: Int, message: String, extraHeaders: [(String, String)])
    }

    init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    func route(
        _ request: HTTPRequest,
        server: MCPServer,
        remoteIP: String?,
        tokenStore: MCPTokenStore?,
        rateLimiter: MCPRateLimiter?
    ) async -> RouteResult {
        if request.path.hasPrefix("/.well-known/") {
            return .httpError(status: 404, message: "Not found")
        }

        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else {
            return .httpError(status: 404, message: "Not found")
        }

        if let rateLimiter, let ip = remoteIP {
            let lockoutCheck = await rateLimiter.isLockedOut(ip: ip)
            if case .rateLimited(let retryAfter) = lockoutCheck {
                let seconds = Int(retryAfter.components.seconds)
                MCPAuditLogger.logRateLimited(ip: ip, retryAfterSeconds: seconds)
                return .httpErrorWithHeaders(
                    status: 429,
                    message: "Too many failed attempts",
                    extraHeaders: [("Retry-After", "\(seconds)")]
                )
            }
        }

        let authResult = await authenticateRequest(
            request,
            remoteIP: remoteIP,
            tokenStore: tokenStore,
            rateLimiter: rateLimiter
        )

        switch authResult {
        case .failure(let result):
            return result
        case .success(let token):
            if token == nil {
                if let origin = request.headers["origin"], !isAllowedOrigin(origin) {
                    return .httpError(status: 403, message: "Forbidden origin")
                }
            }

            switch request.method {
            case .options:
                return handleOptions()
            case .post:
                return await handlePost(request, server: server, authenticatedToken: token)
            case .get:
                return await handleGet(request, server: server)
            case .delete:
                return await handleDelete(request, server: server)
            }
        }
    }

    private enum AuthResult {
        case success(MCPAuthToken?)
        case failure(RouteResult)
    }

    private func authenticateRequest(
        _ request: HTTPRequest,
        remoteIP: String?,
        tokenStore: MCPTokenStore?,
        rateLimiter: MCPRateLimiter?
    ) async -> AuthResult {
        let authRequired = await MainActor.run { AppSettingsManager.shared.mcp.requireAuthentication }

        guard let authHeader = request.headers["authorization"] else {
            guard !authRequired else {
                MCPAuditLogger.logAuthFailure(reason: "Missing authorization header", ip: remoteIP ?? "localhost")
                return .failure(.httpErrorWithHeaders(
                    status: 401,
                    message: "Authentication required",
                    extraHeaders: [("WWW-Authenticate", "Bearer realm=\"TablePro MCP\"")]
                ))
            }
            return .success(nil)
        }

        guard authHeader.lowercased().hasPrefix("bearer "), let tokenStore else {
            let rateLimitResult = await recordAuthFailure(ip: remoteIP, rateLimiter: rateLimiter)
            if case .rateLimited(let retryAfter) = rateLimitResult {
                let seconds = Int(retryAfter.components.seconds)
                MCPAuditLogger.logRateLimited(ip: remoteIP ?? "localhost", retryAfterSeconds: seconds)
                return .failure(.httpErrorWithHeaders(
                    status: 429,
                    message: "Too many failed attempts",
                    extraHeaders: [("Retry-After", "\(seconds)")]
                ))
            }
            MCPAuditLogger.logAuthFailure(reason: "Invalid authorization header format", ip: remoteIP ?? "localhost")
            return .failure(.httpErrorWithHeaders(
                status: 401,
                message: "Invalid authorization header",
                extraHeaders: [("WWW-Authenticate", "Bearer realm=\"TablePro MCP\"")]
            ))
        }

        let bearerToken = String(authHeader.dropFirst(7))

        guard let token = await tokenStore.validate(bearerToken: bearerToken) else {
            let rateLimitResult = await recordAuthFailure(ip: remoteIP, rateLimiter: rateLimiter)
            if case .rateLimited(let retryAfter) = rateLimitResult {
                let seconds = Int(retryAfter.components.seconds)
                MCPAuditLogger.logRateLimited(ip: remoteIP ?? "localhost", retryAfterSeconds: seconds)
                return .failure(.httpErrorWithHeaders(
                    status: 429,
                    message: "Too many failed attempts",
                    extraHeaders: [("Retry-After", "\(seconds)")]
                ))
            }
            MCPAuditLogger.logAuthFailure(reason: "Invalid token", ip: remoteIP ?? "localhost")
            return .failure(.httpErrorWithHeaders(
                status: 401,
                message: "Invalid or expired token",
                extraHeaders: [("WWW-Authenticate", "Bearer realm=\"TablePro MCP\"")]
            ))
        }

        if let rateLimiter, let ip = remoteIP {
            _ = await rateLimiter.checkAndRecord(ip: ip, success: true)
        }
        MCPAuditLogger.logAuthSuccess(tokenName: token.name, ip: remoteIP ?? "localhost")
        return .success(token)
    }

    @discardableResult
    private func recordAuthFailure(
        ip: String?,
        rateLimiter: MCPRateLimiter?
    ) async -> MCPRateLimiter.AuthRateResult? {
        guard let rateLimiter, let ip else { return nil }
        return await rateLimiter.checkAndRecord(ip: ip, success: false)
    }

    private func isAllowedOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin),
              let host = components.host
        else {
            return false
        }
        let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        return allowedHosts.contains(host)
    }

    private func handleOptions() -> RouteResult {
        .noContent
    }

    private func handleGet(_ request: HTTPRequest, server: MCPServer) async -> RouteResult {
        guard let sessionId = request.headers["mcp-session-id"] else {
            return .httpError(status: 400, message: "Missing Mcp-Session-Id header")
        }

        guard let session = await server.session(for: sessionId) else {
            return .httpError(status: 404, message: "Session not found")
        }

        await session.markActive()
        return .sseStream(sessionId: session.id)
    }

    private func handleDelete(_ request: HTTPRequest, server: MCPServer) async -> RouteResult {
        guard let sessionId = request.headers["mcp-session-id"] else {
            return .httpError(status: 400, message: "Missing Mcp-Session-Id header")
        }

        guard await server.session(for: sessionId) != nil else {
            return .httpError(status: 404, message: "Session not found")
        }

        await server.removeSession(sessionId)
        Self.logger.info("Session terminated via DELETE: \(sessionId)")
        return .noContent
    }

    private func handlePost(
        _ request: HTTPRequest,
        server: MCPServer,
        authenticatedToken: MCPAuthToken?
    ) async -> RouteResult {
        if let accept = request.headers["accept"], !accept.contains("application/json") && !accept.contains("*/*") {
            return .httpError(status: 406, message: "Accept header must include application/json")
        }

        guard let body = request.body else {
            return encodeError(MCPError.parseError, id: nil)
        }

        let rpcRequest: JSONRPCRequest
        do {
            rpcRequest = try decoder.decode(JSONRPCRequest.self, from: body)
        } catch {
            return encodeError(MCPError.parseError, id: nil)
        }

        guard rpcRequest.jsonrpc == "2.0" else {
            return encodeError(MCPError.invalidRequest("jsonrpc must be \"2.0\""), id: rpcRequest.id)
        }

        if let protocolVersion = request.headers["mcp-protocol-version"],
           protocolVersion != "2025-03-26"
        {
            Self.logger.warning("Client mcp-protocol-version mismatch: \(protocolVersion)")
        }

        let headerSessionId = request.headers["mcp-session-id"]
        return await dispatchMethod(
            rpcRequest,
            headerSessionId: headerSessionId,
            server: server,
            authenticatedToken: authenticatedToken
        )
    }

    private func dispatchMethod(
        _ request: JSONRPCRequest,
        headerSessionId: String?,
        server: MCPServer,
        authenticatedToken: MCPAuthToken?
    ) async -> RouteResult {
        if request.method == "initialize" {
            return await handleInitialize(request, server: server, authenticatedToken: authenticatedToken)
        }

        if request.method == "ping" {
            return handlePing(request)
        }

        guard let sessionId = headerSessionId else {
            return .httpError(status: 400, message: "Missing Mcp-Session-Id header")
        }
        guard let session = await server.session(for: sessionId) else {
            return .httpError(status: 404, message: "Session not found")
        }

        await session.markActive()

        if request.method == "notifications/initialized" {
            await session.setInitialized(true)
            return .accepted
        }

        if request.method == "notifications/cancelled" {
            return await handleCancellation(request, session: session)
        }

        guard await session.isInitialized else {
            return encodeError(
                MCPError.invalidRequest("Session not initialized. Send notifications/initialized first."),
                id: request.id
            )
        }

        switch request.method {
        case "tools/list":
            return handleToolsList(request, sessionId: sessionId)

        case "tools/call":
            return await handleToolsCall(
                request,
                sessionId: sessionId,
                server: server,
                authenticatedToken: authenticatedToken
            )

        case "resources/list":
            return handleResourcesList(request, sessionId: sessionId)

        case "resources/read":
            return await handleResourcesRead(request, sessionId: sessionId, server: server)

        default:
            return encodeError(MCPError.methodNotFound(request.method), id: request.id)
        }
    }

    private func handleInitialize(
        _ request: JSONRPCRequest,
        server: MCPServer,
        authenticatedToken: MCPAuthToken?
    ) async -> RouteResult {
        guard let session = await server.createSession() else {
            return encodeError(MCPError.internalError("Maximum sessions reached"), id: request.id)
        }

        if let params = request.params,
           let clientInfo = params["clientInfo"],
           let name = clientInfo["name"]?.stringValue
        {
            let version = clientInfo["version"]?.stringValue
            await session.setClientInfo(MCPClientInfo(name: name, version: version))
        }

        if let token = authenticatedToken {
            await session.setAuthenticatedTokenId(token.id)
            await session.setTokenName(token.name)
        }

        let result = MCPInitializeResult(
            protocolVersion: "2025-03-26",
            capabilities: MCPServerCapabilities(
                tools: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false)
            ),
            serverInfo: MCPServerInfo(name: "tablepro", version: "1.0.0")
        )

        return encodeResult(result, id: request.id, sessionId: session.id)
    }

    private func handlePing(_ request: JSONRPCRequest) -> RouteResult {
        guard let id = request.id else {
            return .accepted
        }
        return encodeRawResult(.object([:]), id: id, sessionId: nil)
    }

    private func handleCancellation(
        _ request: JSONRPCRequest,
        session: MCPSession
    ) async -> RouteResult {
        guard let params = request.params,
              let requestIdValue = params["requestId"]
        else {
            return .accepted
        }

        let cancelId: JSONRPCId?
        switch requestIdValue {
        case .string(let s):
            cancelId = .string(s)
        case .int(let i):
            cancelId = .int(i)
        default:
            cancelId = nil
        }

        if let cancelId, let task = await session.removeRunningTask(cancelId) {
            task.cancel()
            Self.logger.info("Cancelled request \(String(describing: cancelId)) in session \(session.id)")
        }

        return .accepted
    }

    private func handleToolsList(_ request: JSONRPCRequest, sessionId: String) -> RouteResult {
        guard let id = request.id else {
            return .accepted
        }

        let tools = Self.toolDefinitions()
        let result: JSONValue = .object(["tools": encodeToolDefinitions(tools)])
        return encodeRawResult(result, id: id, sessionId: sessionId)
    }

    private func handleToolsCall(
        _ request: JSONRPCRequest,
        sessionId: String,
        server: MCPServer,
        authenticatedToken: MCPAuthToken?
    ) async -> RouteResult {
        guard let id = request.id else {
            return encodeError(MCPError.invalidRequest("tools/call requires an id"), id: nil)
        }

        guard let params = request.params,
              let name = params["name"]?.stringValue
        else {
            return encodeError(MCPError.invalidParams("Missing tool name"), id: id)
        }

        let arguments = params["arguments"]

        guard let handler = await server.toolCallHandler else {
            return encodeError(MCPError.internalError("Server not fully initialized"), id: id)
        }

        let session = await server.session(for: sessionId)
        let toolTask = Task {
            try await handler(name, arguments, sessionId, authenticatedToken)
        }
        if let session {
            let cancelForwardingTask = Task<Void, Never> {
                await withTaskCancellationHandler {
                    _ = try? await toolTask.value
                } onCancel: {
                    toolTask.cancel()
                }
            }
            await session.addRunningTask(id, task: cancelForwardingTask)
        }

        do {
            let toolResult = try await toolTask.value
            if let session { _ = await session.removeRunningTask(id) }
            let resultData = try encoder.encode(toolResult)
            guard let resultValue = try? decoder.decode(JSONValue.self, from: resultData) else {
                return encodeError(MCPError.internalError("Failed to encode tool result"), id: id)
            }
            return encodeRawResult(resultValue, id: id, sessionId: sessionId)
        } catch is CancellationError {
            if let session { _ = await session.removeRunningTask(id) }
            return encodeError(MCPError.timeout("Request was cancelled"), id: id)
        } catch let mcpError as MCPError {
            if let session { _ = await session.removeRunningTask(id) }
            return encodeError(mcpError, id: id)
        } catch {
            if let session { _ = await session.removeRunningTask(id) }
            return encodeError(MCPError.internalError(error.localizedDescription), id: id)
        }
    }

    private func handleResourcesList(_ request: JSONRPCRequest, sessionId: String) -> RouteResult {
        guard let id = request.id else {
            return .accepted
        }

        let resources = Self.resourceDefinitions()
        let result: JSONValue = .object(["resources": encodeResourceDefinitions(resources)])
        return encodeRawResult(result, id: id, sessionId: sessionId)
    }

    private func handleResourcesRead(
        _ request: JSONRPCRequest,
        sessionId: String,
        server: MCPServer
    ) async -> RouteResult {
        guard let id = request.id else {
            return encodeError(MCPError.invalidRequest("resources/read requires an id"), id: nil)
        }

        guard let params = request.params,
              let uri = params["uri"]?.stringValue
        else {
            return encodeError(MCPError.invalidParams("Missing resource uri"), id: id)
        }

        guard let handler = await server.resourceReadHandler else {
            return encodeError(MCPError.internalError("Server not fully initialized"), id: id)
        }

        do {
            let readResult = try await handler(uri, sessionId)
            let resultData = try encoder.encode(readResult)
            guard let resultValue = try? decoder.decode(JSONValue.self, from: resultData) else {
                return encodeError(MCPError.internalError("Failed to encode resource result"), id: id)
            }
            return encodeRawResult(resultValue, id: id, sessionId: sessionId)
        } catch let mcpError as MCPError {
            return encodeError(mcpError, id: id)
        } catch {
            return encodeError(MCPError.internalError(error.localizedDescription), id: id)
        }
    }

    private func encodeResult<T: Encodable>(_ result: T, id: JSONRPCId?, sessionId: String?) -> RouteResult {
        guard let id else {
            return .accepted
        }

        do {
            let resultData = try encoder.encode(result)
            let resultValue = try decoder.decode(JSONValue.self, from: resultData)
            let response = JSONRPCResponse(id: id, result: resultValue)
            let data = try encoder.encode(response)
            return .json(data, sessionId: sessionId)
        } catch {
            Self.logger.error("Failed to encode response: \(error.localizedDescription)")
            return encodeError(MCPError.internalError("Encoding failed"), id: id)
        }
    }

    private func encodeRawResult(_ result: JSONValue, id: JSONRPCId, sessionId: String?) -> RouteResult {
        do {
            let response = JSONRPCResponse(id: id, result: result)
            let data = try encoder.encode(response)
            return .json(data, sessionId: sessionId)
        } catch {
            Self.logger.error("Failed to encode response: \(error.localizedDescription)")
            return encodeError(MCPError.internalError("Encoding failed"), id: id)
        }
    }

    private func encodeError(_ error: MCPError, id: JSONRPCId?) -> RouteResult {
        let errorResponse = error.toJsonRpcError(id: id)
        do {
            let data = try encoder.encode(errorResponse)
            return .json(data, sessionId: nil)
        } catch {
            Self.logger.error("Failed to encode error response")
            return .httpError(status: 500, message: "Internal encoding error")
        }
    }

    private func encodeToolDefinitions(_ tools: [MCPToolDefinition]) -> JSONValue {
        .array(tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema
            ])
        })
    }

    private func encodeResourceDefinitions(_ resources: [MCPResourceDefinition]) -> JSONValue {
        .array(resources.map { resource in
            var dict: [String: JSONValue] = [
                "uri": .string(resource.uri),
                "name": .string(resource.name)
            ]
            if let description = resource.description {
                dict["description"] = .string(description)
            }
            if let mimeType = resource.mimeType {
                dict["mimeType"] = .string(mimeType)
            }
            return .object(dict)
        })
    }
}

extension MCPRouter {
    static func toolDefinitions() -> [MCPToolDefinition] {
        connectionTools() + schemaTools() + queryAndExportTools()
    }

    private static func connectionTools() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "list_connections",
                description: "List all saved database connections with their status",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ),
            MCPToolDefinition(
                name: "connect",
                description: "Connect to a saved database",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the saved connection"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "disconnect",
                description: "Disconnect from a database",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection to disconnect"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "get_connection_status",
                description: "Get detailed status of a database connection",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "switch_database",
                description: "Switch the active database on a connection",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "database": .object([
                            "type": "string",
                            "description": "Database name to switch to"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("database")])
                ])
            ),
            MCPToolDefinition(
                name: "switch_schema",
                description: "Switch the active schema on a connection",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Schema name to switch to"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("schema")])
                ])
            )
        ]
    }

    private static func schemaTools() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "list_databases",
                description: "List all databases on the server",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "list_schemas",
                description: "List schemas in a database",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "database": .object([
                            "type": "string",
                            "description": "Database name (uses current if omitted)"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "list_tables",
                description: "List tables and views in a database",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "database": .object([
                            "type": "string",
                            "description": "Database name (uses current if omitted)"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Schema name (uses current if omitted)"
                        ]),
                        "include_row_counts": .object([
                            "type": "boolean",
                            "description": "Include approximate row counts (default false)"
                        ])
                    ]),
                    "required": .array([.string("connection_id")])
                ])
            ),
            MCPToolDefinition(
                name: "describe_table",
                description: "Get detailed table structure: columns, indexes, foreign keys, and DDL",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "table": .object([
                            "type": "string",
                            "description": "Table name"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Schema name (uses current if omitted)"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("table")])
                ])
            ),
            MCPToolDefinition(
                name: "get_table_ddl",
                description: "Get the CREATE TABLE DDL statement for a table",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "table": .object([
                            "type": "string",
                            "description": "Table name"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Schema name (uses current if omitted)"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("table")])
                ])
            )
        ]
    }

    private static func queryAndExportTools() -> [MCPToolDefinition] {
        [
            MCPToolDefinition(
                name: "execute_query",
                description: "Execute a SQL query. All queries are subject to the connection's safe mode policy. "
                    + "DROP/TRUNCATE/ALTER...DROP must use the confirm_destructive_operation tool.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "query": .object([
                            "type": "string",
                            "description": "SQL or NoSQL query text"
                        ]),
                        "max_rows": .object([
                            "type": "integer",
                            "description": "Maximum rows to return (default 500, max 10000)"
                        ]),
                        "timeout_seconds": .object([
                            "type": "integer",
                            "description": "Query timeout in seconds (default 30, max 300)"
                        ]),
                        "database": .object([
                            "type": "string",
                            "description": "Switch to this database before executing"
                        ]),
                        "schema": .object([
                            "type": "string",
                            "description": "Switch to this schema before executing"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("query")])
                ])
            ),
            MCPToolDefinition(
                name: "export_data",
                description: "Export query results or table data to CSV, JSON, or SQL",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the connection"
                        ]),
                        "format": .object([
                            "type": "string",
                            "description": "Export format: csv, json, or sql",
                            "enum": .array([.string("csv"), .string("json"), .string("sql")])
                        ]),
                        "query": .object([
                            "type": "string",
                            "description": "SQL query to export results from"
                        ]),
                        "tables": .object([
                            "type": "array",
                            "description": "Table names to export (alternative to query)",
                            "items": .object(["type": "string"])
                        ]),
                        "output_path": .object([
                            "type": "string",
                            "description": "File path to save export (returns inline data if omitted)"
                        ]),
                        "max_rows": .object([
                            "type": "integer",
                            "description": "Maximum rows to export (default 50000)"
                        ])
                    ]),
                    "required": .array([.string("connection_id"), .string("format")])
                ])
            ),
            MCPToolDefinition(
                name: "confirm_destructive_operation",
                description: "Execute a destructive DDL query (DROP, TRUNCATE, ALTER...DROP) after explicit confirmation.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "connection_id": .object([
                            "type": "string",
                            "description": "UUID of the active connection"
                        ]),
                        "query": .object([
                            "type": "string",
                            "description": "The destructive query to execute"
                        ]),
                        "confirmation_phrase": .object([
                            "type": "string",
                            "description": "Must be exactly: I understand this is irreversible"
                        ])
                    ]),
                    "required": .array([
                        .string("connection_id"),
                        .string("query"),
                        .string("confirmation_phrase")
                    ])
                ])
            )
        ]
    }
}

extension MCPRouter {
    static func resourceDefinitions() -> [MCPResourceDefinition] {
        [
            MCPResourceDefinition(
                uri: "tablepro://connections",
                name: "Saved Connections",
                description: "List of all saved database connections with metadata",
                mimeType: "application/json"
            ),
            MCPResourceDefinition(
                uri: "tablepro://connections/{id}/schema",
                name: "Database Schema",
                description: "Tables, columns, indexes, and foreign keys for a connected database",
                mimeType: "application/json"
            ),
            MCPResourceDefinition(
                uri: "tablepro://connections/{id}/history",
                name: "Query History",
                description: "Recent query history for a connection (supports ?limit=, ?search=, ?date_filter=)",
                mimeType: "application/json"
            )
        ]
    }
}
