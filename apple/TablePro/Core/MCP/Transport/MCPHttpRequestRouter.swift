import Foundation
import os
import TableProMCP

struct MCPHttpRequestRouter: Sendable {
    typealias InboundEmitter = @Sendable (MCPInboundExchange) -> AsyncStream<MCPInboundExchange>.Continuation.YieldResult

    static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpRouter")

    static let mcpPath = "/mcp"
    static let pairingPath = "/v1/integrations/exchange"
    static let revocationPath = "/v1/integrations/revoke"

    let authenticator: any MCPAuthenticator
    let pairingService: MCPPairingService
    let tokenRevoker: any MCPTokenRevoking
    let clock: any MCPClock
    let boundPort: UInt16
    let emitInbound: InboundEmitter

    func dispatch(request: HttpParsedRequest, context: HttpConnectionContext) async {
        let head = request.head
        await context.setOrigin(head.headers.value(for: "Origin"))

        guard MCPHttpHeaderValidator.hostIsLoopback(head, expectedPort: boundPort) else {
            await respondForbiddenHost(context: context)
            return
        }

        if let origin = head.headers.value(for: "Origin"),
           !origin.isEmpty,
           !MCPCorsHeaders.isAllowed(origin: origin) {
            await respondForbiddenOrigin(context: context)
            return
        }

        let path = head.pathWithoutQuery
        switch head.method {
        case .options:
            await context.writeOptionsPreflight()
            await context.completeResponse()
        case .post:
            await routePost(head: head, body: request.body, path: path, context: context)
        default:
            await respondMethodNotAllowedOrNotFound(path: path, context: context)
        }
    }

    private func routePost(
        head: HttpRequestHead,
        body: Data,
        path: String,
        context: HttpConnectionContext
    ) async {
        if path == Self.pairingPath {
            await handlePairingExchange(body: body, context: context)
            return
        }
        if await servesRevocation(path: path, context: context) {
            await handleTokenRevocation(body: body, context: context)
            return
        }
        guard Self.isMcpPath(path) else {
            await respondNotFound(context: context)
            return
        }
        await handleRpc(head: head, body: body, context: context)
    }

    private func respondMethodNotAllowedOrNotFound(path: String, context: HttpConnectionContext) async {
        let isRevocation = await servesRevocation(path: path, context: context)
        guard Self.isMcpPath(path) || path == Self.pairingPath || isRevocation else {
            await respondNotFound(context: context)
            return
        }
        await context.writeMethodNotAllowed()
        await context.completeResponse()
    }

    static func isMcpPath(_ path: String) -> Bool {
        path == mcpPath || path == mcpPath + "/"
    }

    // Only the Unix socket, which admits this user's processes alone; over TCP the path does not exist.
    private func servesRevocation(path: String, context: HttpConnectionContext) async -> Bool {
        guard path == Self.revocationPath else { return false }
        return await context.clientAddress() == .localSocket
    }

    func authenticate(
        headers: HttpHeaders,
        clientAddress: MCPClientAddress
    ) async -> AuthResult {
        let decision = await authenticator.authenticate(
            authorizationHeader: headers.value(for: "Authorization"),
            clientAddress: clientAddress
        )
        switch decision {
        case .allow(let principal):
            return .allow(principal)
        case .deny(let reason):
            return .deny(reason.asProtocolError)
        }
    }

    func respondProtocolError(
        context: HttpConnectionContext,
        error: MCPProtocolError,
        requestId: JsonRpcId?
    ) async {
        let envelope = error.toJsonRpcErrorResponse(id: requestId)
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            Self.logger.error("Encode error envelope failed: \(error.publicLogShape, privacy: .public)")
            data = Self.staticInternalErrorEnvelope
        }
        await context.writeJsonResponse(data: data, status: error.httpStatus, extraHeaders: error.extraHeaders)
        await context.completeResponse()
    }

    private func respondNotFound(context: HttpConnectionContext) async {
        await context.writePlainJsonError(
            status: .notFound,
            error: "not_found",
            errorDescription: String(localized: "TablePro's MCP server does not provide this endpoint.")
        )
        await context.completeResponse()
    }

    private func respondForbiddenOrigin(context: HttpConnectionContext) async {
        await context.writePlainJsonError(
            status: .forbidden,
            error: "forbidden_origin",
            errorDescription: String(localized: "This origin is not allowed to reach TablePro's MCP server.")
        )
        await context.completeResponse()
    }

    private func respondForbiddenHost(context: HttpConnectionContext) async {
        await context.writePlainJsonError(
            status: .forbidden,
            error: "forbidden_host",
            errorDescription: String(localized: "This Host header is not allowed to reach TablePro's MCP server.")
        )
        await context.completeResponse()
    }

    static let staticInternalErrorEnvelope = Data(
        #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal_error"}}"#.utf8
    )

    enum AuthResult: Sendable {
        case allow(MCPPrincipal)
        case deny(MCPProtocolError)
    }
}
