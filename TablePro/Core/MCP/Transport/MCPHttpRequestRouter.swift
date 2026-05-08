import Foundation
import os

struct MCPHttpRequestRouter: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpRouter")

    typealias InboundEmitter = @Sendable (MCPInboundExchange) -> AsyncStream<MCPInboundExchange>.Continuation.YieldResult
    typealias SseStarter = @Sendable (UUID, MCPSessionId, HttpConnectionContext) async -> Void
    typealias ResponderSinkFactory = @Sendable (HttpConnectionContext) -> any MCPResponderSink

    let configuration: MCPHttpServerConfiguration
    let sessionStore: MCPSessionStore
    let authenticator: any MCPAuthenticator
    let clock: any MCPClock
    let emitInbound: InboundEmitter
    let startSse: SseStarter
    let makeResponderSink: ResponderSinkFactory

    func dispatch(head: HttpRequestHead, body: Data, context: HttpConnectionContext) async {
        let clientAddress: MCPClientAddress = await context.clientAddress()
        let now = await clock.now()

        await context.setOrigin(head.headers.value(for: "Origin"))

        if head.method == .post, stripQueryString(head.path) == "/v1/integrations/exchange" {
            await handleIntegrationsExchange(body: body, context: context)
            return
        }

        switch head.method {
        case .options:
            await context.writeOptions204()
            await context.cancel()
        case .get:
            await handleGetMcp(head: head, context: context, clientAddress: clientAddress)
        case .post:
            await handlePostMcp(head: head, body: body, context: context, clientAddress: clientAddress, now: now)
        case .delete:
            await handleDeleteMcp(head: head, context: context, clientAddress: clientAddress)
        default:
            await respondTopLevel(
                context: context,
                error: MCPProtocolError(
                    code: JsonRpcErrorCode.methodNotFound,
                    message: "Method not allowed",
                    httpStatus: .methodNotAllowed
                ),
                requestId: nil
            )
        }
    }

    private func handleIntegrationsExchange(body: Data, context: HttpConnectionContext) async {
        struct ExchangeBody: Decodable {
            let code: String
            let codeVerifier: String
            enum CodingKeys: String, CodingKey {
                case code
                case codeVerifier = "code_verifier"
            }
        }
        struct ExchangeResponse: Encodable {
            let token: String
        }

        Self.logger.info("Integrations exchange request received (\(body.count, privacy: .public) bytes)")
        let ip = Self.ipString(for: await context.clientAddress())

        let parsed: ExchangeBody
        do {
            parsed = try JSONDecoder().decode(ExchangeBody.self, from: body)
        } catch {
            Self.logger.warning("Integrations exchange decode failed: \(error.localizedDescription, privacy: .public)")
            MCPAuditLogger.logPairingExchange(outcome: .denied, ip: ip, details: "invalid JSON body")
            await context.writePlainJsonError(status: .badRequest, message: "Invalid JSON body")
            await context.cancel()
            return
        }

        guard !parsed.code.isEmpty, !parsed.codeVerifier.isEmpty else {
            Self.logger.warning("Integrations exchange missing code or verifier")
            MCPAuditLogger.logPairingExchange(
                outcome: .denied,
                ip: ip,
                details: "missing code or code_verifier"
            )
            await context.writePlainJsonError(status: .badRequest, message: "Missing code or code_verifier")
            await context.cancel()
            return
        }

        guard parsed.code.utf8.count <= 1_024, parsed.codeVerifier.utf8.count <= 1_024 else {
            Self.logger.warning("Integrations exchange field exceeds size cap")
            MCPAuditLogger.logPairingExchange(
                outcome: .denied,
                ip: ip,
                details: "field exceeds 1_024 bytes"
            )
            await context.writePlainJsonError(status: .badRequest, message: "Field exceeds size limit")
            await context.cancel()
            return
        }

        let exchange = PairingExchange(code: parsed.code, verifier: parsed.codeVerifier)
        let outcome: Result<String, Error>
        do {
            let token = try await MCPPairingService.shared.exchange(exchange)
            outcome = .success(token)
        } catch {
            outcome = .failure(error)
        }

        switch outcome {
        case .success(let token):
            Self.logger.info("Integrations exchange succeeded (token len=\(token.count, privacy: .public))")
            let label = await Self.resolveTokenLabel(for: token)
            MCPAuditLogger.logPairingExchange(outcome: .success, tokenName: label, ip: ip)
            let payload = (try? JSONEncoder().encode(ExchangeResponse(token: token))) ?? Data()
            await context.writePlainJsonResponse(status: .ok, body: payload)
            await context.cancel()
        case .failure(let error):
            let mapped = Self.mapExchangeError(error)
            Self.logger.warning("Integrations exchange failed: status=\(mapped.status.code, privacy: .public) reason=\(mapped.message, privacy: .public)")
            MCPAuditLogger.logPairingExchange(
                outcome: .denied,
                ip: ip,
                details: mapped.message
            )
            await context.writePlainJsonError(status: mapped.status, message: mapped.message)
            await context.cancel()
        }
    }

    private static func ipString(for address: MCPClientAddress) -> String {
        switch address {
        case .loopback:
            return "127.0.0.1"
        case .remote(let host):
            return host
        }
    }

    private static func resolveTokenLabel(for plaintext: String) async -> String? {
        let store: MCPTokenStore? = await MainActor.run { MCPServerManager.shared.tokenStore }
        guard let store else { return nil }
        return await store.validate(bearerToken: plaintext)?.name
    }

    private static func mapExchangeError(_ error: Error) -> (status: HttpStatus, message: String) {
        guard let domainError = error as? MCPDataLayerError else {
            return (.internalServerError, "Internal error")
        }
        switch domainError {
        case .notFound:
            return (.notFound, "Pairing code not found")
        case .expired:
            return (HttpStatus(code: 410, reasonPhrase: "Gone"), "Pairing code expired")
        case .forbidden:
            return (.forbidden, "Challenge mismatch")
        default:
            return (.internalServerError, "Internal error")
        }
    }

    private func handleGetMcp(
        head: HttpRequestHead,
        context: HttpConnectionContext,
        clientAddress: MCPClientAddress
    ) async {
        guard pathMatchesMcp(head.path) else {
            await respondTopLevel(
                context: context,
                error: MCPProtocolError(
                    code: JsonRpcErrorCode.methodNotFound,
                    message: "Method not found",
                    httpStatus: .notFound
                ),
                requestId: nil
            )
            return
        }

        guard let sessionIdRaw = head.headers.value(for: "Mcp-Session-Id") else {
            await respondTopLevel(context: context, error: .missingSessionId(), requestId: nil)
            return
        }

        if head.headers.value(for: "Last-Event-ID") != nil {
            await respondTopLevel(
                context: context,
                error: MCPProtocolError(
                    code: JsonRpcErrorCode.serverError,
                    message: "SSE event replay is not supported",
                    httpStatus: .notImplemented
                ),
                requestId: nil
            )
            return
        }

        if let accept = head.headers.value(for: "Accept"),
           !accept.lowercased().contains("text/event-stream"),
           !accept.contains("*/*") {
            await respondTopLevel(context: context, error: .notAcceptable(), requestId: nil)
            return
        }

        let authResult = await authenticate(headers: head.headers, clientAddress: clientAddress)
        guard case .allow = authResult else {
            if case .deny(let error) = authResult {
                await respondTopLevel(context: context, error: error, requestId: nil)
            }
            return
        }

        let sessionId = MCPSessionId(sessionIdRaw)
        guard await sessionStore.session(id: sessionId) != nil else {
            await respondTopLevel(context: context, error: .sessionNotFound(), requestId: nil)
            return
        }

        await sessionStore.touch(id: sessionId)

        await startSse(context.id, sessionId, context)
        Self.logger.info("Registered SSE notification stream for session \(sessionId.rawValue, privacy: .public)")
    }

    private func handlePostMcp(
        head: HttpRequestHead,
        body: Data,
        context: HttpConnectionContext,
        clientAddress: MCPClientAddress,
        now: Date
    ) async {
        guard pathMatchesMcp(head.path) else {
            await respondTopLevel(
                context: context,
                error: MCPProtocolError(
                    code: JsonRpcErrorCode.methodNotFound,
                    message: "Method not found",
                    httpStatus: .notFound
                ),
                requestId: nil
            )
            return
        }

        if body.count > configuration.limits.maxRequestBodyBytes {
            await respondTopLevel(context: context, error: .payloadTooLarge(), requestId: nil)
            return
        }

        let authResult = await authenticate(headers: head.headers, clientAddress: clientAddress)
        guard case .allow(let principal) = authResult else {
            if case .deny(let error) = authResult {
                await respondTopLevel(context: context, error: error, requestId: nil)
            }
            return
        }

        let message: JsonRpcMessage
        do {
            message = try JsonRpcCodec.decode(body)
        } catch {
            await respondTopLevel(
                context: context,
                error: .parseError(detail: String(describing: error)),
                requestId: nil
            )
            return
        }

        let requestId = extractRequestId(from: message)
        let methodName = extractMethod(from: message)
        let mcpProtocolVersion = head.headers.value(for: "mcp-protocol-version")

        let sessionId: MCPSessionId?
        if methodName == "initialize" {
            do {
                let session = try await sessionStore.create()
                sessionId = session.id
            } catch {
                await respondTopLevel(
                    context: context,
                    error: .serviceUnavailable(),
                    requestId: requestId
                )
                return
            }
        } else {
            guard let raw = head.headers.value(for: "Mcp-Session-Id") else {
                await respondTopLevel(context: context, error: .missingSessionId(), requestId: requestId)
                return
            }
            let candidate = MCPSessionId(raw)
            guard let session = await sessionStore.session(id: candidate) else {
                await respondTopLevel(context: context, error: .sessionNotFound(), requestId: requestId)
                return
            }
            if let mismatch = await Self.protocolVersionMismatch(
                session: session,
                headerValue: mcpProtocolVersion
            ) {
                await respondTopLevel(context: context, error: mismatch, requestId: requestId)
                return
            }
            sessionId = candidate
            await sessionStore.touch(id: candidate)
        }

        let sink = makeResponderSink(context)
        let responder = MCPExchangeResponder(sink: sink, requestId: requestId)

        let exchangeContext = MCPInboundContext(
            sessionId: sessionId,
            principal: principal,
            clientAddress: clientAddress,
            receivedAt: now,
            mcpProtocolVersion: mcpProtocolVersion
        )
        let exchange = MCPInboundExchange(
            message: message,
            context: exchangeContext,
            responder: responder
        )
        let yieldResult = emitInbound(exchange)
        if case .dropped = yieldResult {
            Self.logger.warning("exchanges buffer full, dropped inbound message; dispatcher is falling behind")
        }
    }

    private func handleDeleteMcp(
        head: HttpRequestHead,
        context: HttpConnectionContext,
        clientAddress: MCPClientAddress
    ) async {
        guard pathMatchesMcp(head.path) else {
            await respondTopLevel(
                context: context,
                error: MCPProtocolError(
                    code: JsonRpcErrorCode.methodNotFound,
                    message: "Method not found",
                    httpStatus: .notFound
                ),
                requestId: nil
            )
            return
        }

        let authResult = await authenticate(headers: head.headers, clientAddress: clientAddress)
        guard case .allow = authResult else {
            if case .deny(let error) = authResult {
                await respondTopLevel(context: context, error: error, requestId: nil)
            }
            return
        }

        guard let raw = head.headers.value(for: "Mcp-Session-Id") else {
            await respondTopLevel(context: context, error: .missingSessionId(), requestId: nil)
            return
        }

        let sessionId = MCPSessionId(raw)
        guard await sessionStore.session(id: sessionId) != nil else {
            await respondTopLevel(context: context, error: .sessionNotFound(), requestId: nil)
            return
        }

        await sessionStore.terminate(id: sessionId, reason: .clientRequested)
        await context.writeNoContent()
        await context.cancel()
    }

    private func authenticate(
        headers: HttpHeaders,
        clientAddress: MCPClientAddress
    ) async -> AuthResult {
        let authHeader = headers.value(for: "Authorization")
        let decision = await authenticator.authenticate(
            authorizationHeader: authHeader,
            clientAddress: clientAddress
        )
        switch decision {
        case .allow(let principal):
            return .allow(principal)
        case .deny(let reason):
            let mcpError = mapDenialToProtocolError(reason)
            return .deny(mcpError)
        }
    }

    private func mapDenialToProtocolError(_ reason: MCPAuthDenialReason) -> MCPProtocolError {
        switch reason.httpStatus {
        case 401:
            if let challenge = reason.challenge {
                if challenge.contains("invalid_token") {
                    if challenge.contains("token_expired") || challenge.contains("token expired") {
                        return .tokenExpired()
                    }
                    return .tokenInvalid()
                }
                return .unauthenticated(challenge: challenge)
            }
            return .unauthenticated()
        case 403:
            return .forbidden(reason: reason.logMessage)
        case 429:
            return .rateLimited(retryAfterSeconds: reason.retryAfterSeconds)
        default:
            return MCPProtocolError(
                code: JsonRpcErrorCode.serverError,
                message: reason.logMessage,
                httpStatus: HttpStatus(code: reason.httpStatus, reasonPhrase: "Error"),
                extraHeaders: reason.challenge.map { [("WWW-Authenticate", $0)] } ?? []
            )
        }
    }

    private func respondTopLevel(
        context: HttpConnectionContext,
        error: MCPProtocolError,
        requestId: JsonRpcId?
    ) async {
        let envelope = error.toJsonRpcErrorResponse(id: requestId)
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        await context.writeJsonResponse(
            data: data,
            status: error.httpStatus,
            sessionId: nil,
            extraHeaders: error.extraHeaders
        )
        await context.cancel()
    }

    private func pathMatchesMcp(_ path: String) -> Bool {
        let trimmed = stripQueryString(path)
        return trimmed == "/mcp" || trimmed == "/mcp/"
    }

    private static func protocolVersionMismatch(
        session: MCPSession,
        headerValue: String?
    ) async -> MCPProtocolError? {
        let state = await session.state
        guard case .ready = state else { return nil }
        guard let negotiated = await session.negotiatedProtocolVersion else { return nil }
        guard let headerValue, !headerValue.isEmpty else { return nil }
        if headerValue == negotiated { return nil }
        return .invalidRequest(
            detail: "MCP-Protocol-Version mismatch: client sent \(headerValue), session negotiated \(negotiated)"
        )
    }

    private func stripQueryString(_ path: String) -> String {
        if let questionIndex = path.firstIndex(of: "?") {
            return String(path[path.startIndex..<questionIndex])
        }
        return path
    }

    private func extractRequestId(from message: JsonRpcMessage) -> JsonRpcId? {
        switch message {
        case .request(let request):
            return request.id
        case .successResponse(let response):
            return response.id
        case .errorResponse(let response):
            return response.id
        case .notification:
            return nil
        }
    }

    private func extractMethod(from message: JsonRpcMessage) -> String? {
        switch message {
        case .request(let request):
            return request.method
        case .notification(let notification):
            return notification.method
        case .successResponse, .errorResponse:
            return nil
        }
    }

    enum AuthResult {
        case allow(MCPPrincipal)
        case deny(MCPProtocolError)
    }
}
