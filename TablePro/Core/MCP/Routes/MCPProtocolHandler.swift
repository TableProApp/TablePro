import Foundation
import os

final class MCPProtocolHandler: MCPRouteHandler, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPProtocolHandler")

    private weak var server: MCPServer?
    private let tokenStore: MCPTokenStore?
    private let rateLimiter: MCPRateLimiter?

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    var methods: [HTTPRequest.Method] { [.get, .post, .delete] }
    var path: String { "/mcp" }

    init(server: MCPServer, tokenStore: MCPTokenStore?, rateLimiter: MCPRateLimiter?) {
        self.server = server
        self.tokenStore = tokenStore
        self.rateLimiter = rateLimiter
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    func handle(_ request: HTTPRequest) async -> MCPRouter.RouteResult {
        guard let server else {
            return .httpError(status: 503, message: "Server unavailable")
        }

        if let rateLimiter, let ip = request.remoteIP {
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

        let authResult = await authenticateRequest(request)

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
            case .post:
                return await handlePost(request, server: server, authenticatedToken: token)
            case .get:
                return await handleGet(request, server: server)
            case .delete:
                return await handleDelete(request, server: server)
            case .options:
                return .noContent
            }
        }
    }

    private enum AuthResult {
        case success(MCPAuthToken?)
        case failure(MCPRouter.RouteResult)
    }

    private func authenticateRequest(_ request: HTTPRequest) async -> AuthResult {
        let remoteIP = request.remoteIP
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
            let rateLimitResult = await recordAuthFailure(ip: remoteIP)
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
            let rateLimitResult = await recordAuthFailure(ip: remoteIP)
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
    private func recordAuthFailure(ip: String?) async -> MCPRateLimiter.AuthRateResult? {
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

    private func handleGet(_ request: HTTPRequest, server: MCPServer) async -> MCPRouter.RouteResult {
        guard let sessionId = request.headers["mcp-session-id"] else {
            return .httpError(status: 400, message: "Missing Mcp-Session-Id header")
        }

        guard let session = await server.session(for: sessionId) else {
            return .httpError(status: 404, message: "Session not found")
        }

        await session.markActive()
        return .sseStream(sessionId: session.id)
    }

    private func handleDelete(_ request: HTTPRequest, server: MCPServer) async -> MCPRouter.RouteResult {
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
    ) async -> MCPRouter.RouteResult {
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
    ) async -> MCPRouter.RouteResult {
        if request.method == "initialize" {
            return await handleInitialize(request, server: server)
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
            do {
                try await session.transition(to: .active(
                    tokenId: authenticatedToken?.id,
                    tokenName: authenticatedToken?.name
                ))
            } catch {
                return encodeError(MCPError.invalidRequest("Cannot initialize session in current phase"), id: request.id)
            }
            return .accepted
        }

        if request.method == "notifications/cancelled" {
            return await handleCancellation(request, session: session)
        }

        guard await session.phase.isActive else {
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
        server: MCPServer
    ) async -> MCPRouter.RouteResult {
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

        do {
            try await session.transition(to: .initializing)
        } catch {
            await server.removeSession(session.id)
            return encodeError(MCPError.invalidRequest("Cannot initialize session"), id: request.id)
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

    private func handlePing(_ request: JSONRPCRequest) -> MCPRouter.RouteResult {
        guard let id = request.id else {
            return .accepted
        }
        return encodeRawResult(.object([:]), id: id, sessionId: nil)
    }

    private func handleCancellation(
        _ request: JSONRPCRequest,
        session: MCPSession
    ) async -> MCPRouter.RouteResult {
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

    private func handleToolsList(_ request: JSONRPCRequest, sessionId: String) -> MCPRouter.RouteResult {
        guard let id = request.id else {
            return .accepted
        }

        let tools = MCPRouter.toolDefinitions()
        let result: JSONValue = .object(["tools": encodeToolDefinitions(tools)])
        return encodeRawResult(result, id: id, sessionId: sessionId)
    }

    private func handleToolsCall(
        _ request: JSONRPCRequest,
        sessionId: String,
        server: MCPServer,
        authenticatedToken: MCPAuthToken?
    ) async -> MCPRouter.RouteResult {
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

    private func handleResourcesList(_ request: JSONRPCRequest, sessionId: String) -> MCPRouter.RouteResult {
        guard let id = request.id else {
            return .accepted
        }

        let resources = MCPRouter.resourceDefinitions()
        let result: JSONValue = .object(["resources": encodeResourceDefinitions(resources)])
        return encodeRawResult(result, id: id, sessionId: sessionId)
    }

    private func handleResourcesRead(
        _ request: JSONRPCRequest,
        sessionId: String,
        server: MCPServer
    ) async -> MCPRouter.RouteResult {
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

    private func encodeResult<T: Encodable>(_ result: T, id: JSONRPCId?, sessionId: String?) -> MCPRouter.RouteResult {
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

    private func encodeRawResult(_ result: JSONValue, id: JSONRPCId, sessionId: String?) -> MCPRouter.RouteResult {
        do {
            let response = JSONRPCResponse(id: id, result: result)
            let data = try encoder.encode(response)
            return .json(data, sessionId: sessionId)
        } catch {
            Self.logger.error("Failed to encode response: \(error.localizedDescription)")
            return encodeError(MCPError.internalError("Encoding failed"), id: id)
        }
    }

    private func encodeError(_ error: MCPError, id: JSONRPCId?) -> MCPRouter.RouteResult {
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
