import Foundation
import Network
import os
import Security

public enum MCPHttpServerState: Sendable, Equatable {
    case idle
    case starting
    case running(port: UInt16)
    case stopped
    case failed(reason: String)
}

public actor MCPHttpServerTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpServer")

    private let configuration: MCPHttpServerConfiguration
    private let sessionStore: MCPSessionStore
    private let authenticator: any MCPAuthenticator
    private let clock: any MCPClock

    private var listener: NWListener?
    private var connections: [UUID: HttpConnectionContext] = [:]
    private var sseConnectionsBySession: [MCPSessionId: UUID] = [:]
    private var sessionEventsTask: Task<Void, Never>?

    nonisolated public let exchanges: AsyncStream<MCPInboundExchange>
    nonisolated private let exchangesContinuation: AsyncStream<MCPInboundExchange>.Continuation

    nonisolated public let listenerState: AsyncStream<MCPHttpServerState>
    nonisolated private let stateContinuation: AsyncStream<MCPHttpServerState>.Continuation

    private var currentState: MCPHttpServerState = .idle

    public init(
        configuration: MCPHttpServerConfiguration,
        sessionStore: MCPSessionStore,
        authenticator: any MCPAuthenticator,
        clock: any MCPClock = MCPSystemClock()
    ) {
        self.configuration = configuration
        self.sessionStore = sessionStore
        self.authenticator = authenticator
        self.clock = clock

        let (exchanges, exchangesContinuation) = AsyncStream<MCPInboundExchange>.makeStream(
            bufferingPolicy: .bufferingOldest(1024)
        )
        self.exchanges = exchanges
        self.exchangesContinuation = exchangesContinuation

        let (listenerState, stateContinuation) = AsyncStream<MCPHttpServerState>.makeStream()
        self.listenerState = listenerState
        self.stateContinuation = stateContinuation
    }

    public func start() async throws {
        guard listener == nil else {
            Self.logger.warning("start() called while listener already exists")
            throw MCPHttpServerError.alreadyStarted
        }

        Self.logger.info("Starting MCP HTTP server: bind=\(String(describing: self.configuration.bindAddress)) port=\(self.configuration.port) tls=\(self.configuration.tls != nil)")

        if configuration.bindAddress == .anyInterface, configuration.tls == nil {
            Self.logger.error("Remote access requested without TLS — refusing to start")
            throw MCPHttpServerError.tlsRequiredForRemoteAccess
        }

        emitState(.starting)

        let parameters: NWParameters = makeParameters()

        do {
            let newListener = try NWListener(using: parameters)
            listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.handleListenerState(state) }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { await self.handleNewConnection(connection) }
            }

            newListener.start(queue: .global(qos: .userInitiated))
            startSessionEventListener()
        } catch {
            emitState(.failed(reason: error.localizedDescription))
            listener = nil
            throw MCPHttpServerError.bindFailed(reason: error.localizedDescription)
        }
    }

    public func stop() async {
        Self.logger.info("Stopping MCP HTTP server")

        sessionEventsTask?.cancel()
        sessionEventsTask = nil

        for (_, context) in connections {
            await context.cancel()
        }
        connections.removeAll()
        sseConnectionsBySession.removeAll()

        if let listener {
            self.listener = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state {
                        continuation.resume()
                    }
                }
                listener.cancel()
            }
        }

        emitState(.stopped)
        exchangesContinuation.finish()
        stateContinuation.finish()
    }

    public func sendNotification(_ notification: JsonRpcNotification, toSession sessionId: MCPSessionId) async {
        guard let connectionId = sseConnectionsBySession[sessionId],
              let context = connections[connectionId] else {
            return
        }

        let message = JsonRpcMessage.notification(notification)
        guard let data = try? JsonRpcCodec.encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        await context.writeSseFrame(SseFrame(data: text))
    }

    public func broadcastNotification(_ notification: JsonRpcNotification) async {
        let sessionIds = Array(sseConnectionsBySession.keys)
        for sessionId in sessionIds {
            await sendNotification(notification, toSession: sessionId)
        }
    }

    private func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()

        let parameters: NWParameters
        if let tls = configuration.tls {
            let tlsOptions = NWProtocolTLS.Options()
            if let secIdentity = sec_identity_create(tls.identity) {
                sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
            }
            switch tls.minimumProtocol {
            case .tls12:
                sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            case .tls13:
                sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
            }
            parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }

        let host: NWEndpoint.Host = configuration.bindAddress == .loopback ? .ipv4(.loopback) : .ipv4(.any)
        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? configuration.port
            Self.logger.info("MCP HTTP server listening on port \(port, privacy: .public)")
            emitState(.running(port: port))

        case .failed(let error):
            Self.logger.error("MCP HTTP listener failed: \(error.localizedDescription, privacy: .public)")
            emitState(.failed(reason: error.localizedDescription))
            listener?.cancel()
            listener = nil

        case .cancelled:
            Self.logger.debug("MCP HTTP listener cancelled")

        default:
            break
        }
    }

    private func emitState(_ state: MCPHttpServerState) {
        currentState = state
        stateContinuation.yield(state)
    }

    private func startSessionEventListener() {
        sessionEventsTask?.cancel()
        let store = sessionStore
        sessionEventsTask = Task { [weak self] in
            let eventsStream = await store.events
            for await event in eventsStream {
                guard let self else { return }
                if case .terminated(let sessionId, let reason) = event {
                    await self.handleSessionTerminated(sessionId, reason: reason)
                }
            }
        }
    }

    private func handleSessionTerminated(_ sessionId: MCPSessionId, reason: MCPSessionTerminationReason) async {
        guard let connectionId = sseConnectionsBySession.removeValue(forKey: sessionId),
              let context = connections[connectionId] else {
            return
        }

        let comment: String
        switch reason {
        case .idleTimeout:
            comment = "idle-timeout"
        case .tokenRevoked:
            comment = "token-revoked"
        case .serverShutdown:
            comment = "server-shutdown"
        case .clientRequested:
            comment = "client-disconnect"
        case .capacityEvicted:
            comment = "capacity-evicted"
        }
        await context.writeRaw(Data("\u{003A} \(comment)\n\n".utf8))
        await context.cancel()
        connections.removeValue(forKey: connectionId)
    }

    private func handleNewConnection(_ connection: NWConnection) async {
        let connectionId = UUID()
        Self.logger.debug("Accepted connection \(connectionId, privacy: .public)")
        let context = HttpConnectionContext(id: connectionId, connection: connection)
        connections[connectionId] = context
        await context.start { [weak self] data in
            guard let self else { return }
            await self.handleReceivedData(connectionId: connectionId, data: data)
        } onClosed: { [weak self] in
            guard let self else { return }
            await self.removeConnection(connectionId: connectionId)
        }
    }

    private func removeConnection(connectionId: UUID) async {
        connections.removeValue(forKey: connectionId)
        let pairs = sseConnectionsBySession.filter { $0.value == connectionId }
        for (sessionId, _) in pairs {
            sseConnectionsBySession.removeValue(forKey: sessionId)
        }
    }

    private func handleReceivedData(connectionId: UUID, data: Data) async {
        guard let context = connections[connectionId] else { return }

        let parseResult: HttpRequestParseResult
        do {
            parseResult = try HttpRequestParser.parse(data)
        } catch HttpRequestParseError.bodyTooLarge {
            await respondTopLevel(context: context, error: .payloadTooLarge(), requestId: nil)
            return
        } catch HttpRequestParseError.headerTooLarge {
            await respondTopLevel(context: context, error: .payloadTooLarge(), requestId: nil)
            return
        } catch {
            await respondTopLevel(
                context: context,
                error: .invalidRequest(detail: "Malformed HTTP"),
                requestId: nil
            )
            return
        }

        switch parseResult {
        case .incomplete:
            return
        case .complete(let head, let body, _):
            await context.markRequestComplete()
            await dispatch(head: head, body: body, context: context)
        }
    }

    private func dispatch(head: HttpRequestHead, body: Data, context: HttpConnectionContext) async {
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
            return
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

        guard parsed.code.utf8.count <= 1024, parsed.codeVerifier.utf8.count <= 1024 else {
            Self.logger.warning("Integrations exchange field exceeds size cap")
            MCPAuditLogger.logPairingExchange(
                outcome: .denied,
                ip: ip,
                details: "field exceeds 1024 bytes"
            )
            await context.writePlainJsonError(status: .badRequest, message: "Field exceeds size limit")
            await context.cancel()
            return
        }

        let exchange = PairingExchange(code: parsed.code, verifier: parsed.codeVerifier)
        let outcome: Result<String, Error> = await MainActor.run {
            do {
                return .success(try MCPPairingService.shared.exchange(exchange))
            } catch {
                return .failure(error)
            }
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

        registerSseConnection(connectionId: context.id, sessionId: sessionId)
        await context.writeSseStreamHeaders(sessionId: sessionId)
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

        let sink = TransportResponderSink(transport: self, context: context)
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
        let yieldResult = exchangesContinuation.yield(exchange)
        if case .dropped = yieldResult {
            Self.logger.warning("exchanges buffer full, dropped inbound message — dispatcher is falling behind")
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

    fileprivate func registerSseConnection(connectionId: UUID, sessionId: MCPSessionId) {
        if let previous = sseConnectionsBySession[sessionId], previous != connectionId,
           let oldContext = connections[previous] {
            Task { await oldContext.cancel() }
            connections.removeValue(forKey: previous)
        }
        sseConnectionsBySession[sessionId] = connectionId
    }

    private enum AuthResult {
        case allow(MCPPrincipal)
        case deny(MCPProtocolError)
    }
}

actor HttpConnectionContext {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpServer")

    nonisolated let id: UUID
    private let connection: NWConnection
    private var receiveBuffer = Data()
    private var requestComplete = false
    private var cancelled = false
    private var sseActive = false
    private var origin: String?

    init(id: UUID, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }

    func setOrigin(_ value: String?) {
        origin = value
    }

    private func corsHeaders() -> [(String, String)] {
        MCPCorsHeaders.headers(forOrigin: origin)
    }

    func start(
        onData: @escaping @Sendable (Data) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) {
        let nwConnection = connection
        nwConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.beginReading(onData: onData, onClosed: onClosed) }
            case .failed:
                Task { await self.handleClosed(onClosed: onClosed) }
            case .cancelled:
                Task { await self.handleClosed(onClosed: onClosed) }
            default:
                break
            }
        }
        nwConnection.start(queue: .global(qos: .userInitiated))
    }

    private func beginReading(
        onData: @escaping @Sendable (Data) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) {
        scheduleReceive(onData: onData, onClosed: onClosed)
    }

    private func scheduleReceive(
        onData: @escaping @Sendable (Data) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) {
        if cancelled || requestComplete { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleReceive(
                    content: content,
                    isComplete: isComplete,
                    error: error,
                    onData: onData,
                    onClosed: onClosed
                )
            }
        }
    }

    private func handleReceive(
        content: Data?,
        isComplete: Bool,
        error: NWError?,
        onData: @escaping @Sendable (Data) async -> Void,
        onClosed: @escaping @Sendable () async -> Void
    ) async {
        if let error {
            Self.logger.debug("Receive error: \(error.localizedDescription, privacy: .public)")
            cancel()
            await onClosed()
            return
        }

        if let content {
            receiveBuffer.append(content)
            await onData(receiveBuffer)
        }

        if isComplete {
            cancel()
            await onClosed()
            return
        }

        if !requestComplete, !cancelled {
            scheduleReceive(onData: onData, onClosed: onClosed)
        }
    }

    private func handleClosed(onClosed: @escaping @Sendable () async -> Void) async {
        if !cancelled {
            cancelled = true
        }
        await onClosed()
    }

    func markRequestComplete() {
        requestComplete = true
    }

    func clientAddress() -> MCPClientAddress {
        guard let endpoint = connection.currentPath?.remoteEndpoint,
              case .hostPort(let host, _) = endpoint else {
            return .loopback
        }
        let hostString = "\(host)"
        if hostString == "127.0.0.1" || hostString == "::1" || hostString.lowercased() == "localhost" {
            return .loopback
        }
        return .remote(hostString)
    }

    func writeJsonResponse(
        data: Data,
        status: HttpStatus,
        sessionId: MCPSessionId?,
        extraHeaders: [(String, String)]
    ) async {
        if cancelled { return }
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Connection", "close")
        ]
        if let sessionId {
            headers.append(("Mcp-Session-Id", sessionId.rawValue))
        }
        headers.append(contentsOf: extraHeaders)
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: status, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: data)
        await send(payload)
    }

    func writePlainJsonResponse(status: HttpStatus, body: Data) async {
        if cancelled { return }
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Connection", "close")
        ]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: status, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: body)
        await send(payload)
    }

    func writePlainJsonError(status: HttpStatus, message: String) async {
        struct ErrorBody: Encodable { let error: String }
        let payload = (try? JSONEncoder().encode(ErrorBody(error: message))) ?? Data()
        await writePlainJsonResponse(status: status, body: payload)
    }

    func writeOptions204() async {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: .noContent, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        await send(payload)
    }

    func writeNoContent() async {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: .noContent, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        await send(payload)
    }

    func writeAccepted() async {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: .accepted, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        await send(payload)
    }

    func writeSseStreamHeaders(sessionId: MCPSessionId) async {
        if cancelled { return }
        sseActive = true
        var headers: [(String, String)] = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
            ("Mcp-Session-Id", sessionId.rawValue)
        ]
        headers.append(contentsOf: self.corsHeaders())
        let head = HttpResponseHead(status: .ok, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        await send(payload)
    }

    func writeSseFrame(_ frame: SseFrame) async {
        if cancelled { return }
        let data = SseEncoder.encode(frame)
        await send(data)
    }

    func writeRaw(_ data: Data) async {
        if cancelled { return }
        await send(data)
    }

    func cancel() {
        if cancelled { return }
        cancelled = true
        connection.cancel()
    }

    func isSseActive() -> Bool {
        sseActive
    }

    private func send(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    Self.logger.debug("Send error: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume()
            })
        }
    }
}

struct TransportResponderSink: MCPResponderSink {
    let transport: MCPHttpServerTransport
    let context: HttpConnectionContext

    func writeJson(_ data: Data, status: HttpStatus, sessionId: MCPSessionId?, extraHeaders: [(String, String)]) async {
        await context.writeJsonResponse(
            data: data,
            status: status,
            sessionId: sessionId,
            extraHeaders: extraHeaders
        )
    }

    func writeAccepted() async {
        await context.writeAccepted()
    }

    func writeSseStreamHeaders(sessionId: MCPSessionId) async {
        await context.writeSseStreamHeaders(sessionId: sessionId)
    }

    func writeSseFrame(_ frame: SseFrame) async {
        await context.writeSseFrame(frame)
    }

    func closeConnection() async {
        await context.cancel()
    }

    func registerSseConnection(sessionId: MCPSessionId) async {
        await transport.registerSseConnection(connectionId: context.id, sessionId: sessionId)
    }
}
