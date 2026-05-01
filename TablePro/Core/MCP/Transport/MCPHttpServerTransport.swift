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

    private var exchangesContinuation: AsyncStream<MCPInboundExchange>.Continuation?
    private let exchangesStorage: AsyncStream<MCPInboundExchange>

    private var stateContinuation: AsyncStream<MCPHttpServerState>.Continuation?
    private let listenerStateStorage: AsyncStream<MCPHttpServerState>

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

        var exchangeContinuation: AsyncStream<MCPInboundExchange>.Continuation?
        self.exchangesStorage = AsyncStream<MCPInboundExchange> { continuation in
            exchangeContinuation = continuation
        }
        self.exchangesContinuation = exchangeContinuation

        var stateCont: AsyncStream<MCPHttpServerState>.Continuation?
        self.listenerStateStorage = AsyncStream<MCPHttpServerState> { continuation in
            stateCont = continuation
        }
        self.stateContinuation = stateCont
    }

    nonisolated public var exchanges: AsyncStream<MCPInboundExchange> {
        exchangesStorage
    }

    nonisolated public var listenerState: AsyncStream<MCPHttpServerState> {
        listenerStateStorage
    }

    public func start() async throws {
        guard listener == nil else {
            throw MCPHttpServerError.alreadyStarted
        }

        if configuration.bindAddress == .anyInterface, configuration.tls == nil {
            throw MCPHttpServerError.tlsRequiredForRemoteAccess
        }

        emitState(.starting)

        let parameters: NWParameters = makeParameters()

        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any

        do {
            let newListener = try NWListener(using: parameters, on: port)
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
        stateContinuation?.yield(state)
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

        if reason == .idleTimeout {
            await context.writeRaw(Data("\u{003A} idle-timeout\n\n".utf8))
        }
        await context.cancel()
        connections.removeValue(forKey: connectionId)
    }

    private func handleNewConnection(_ connection: NWConnection) async {
        let connectionId = UUID()
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

        if data.count > configuration.limits.maxRequestBodyBytes + configuration.limits.maxHeaderBytes {
            await respondTopLevel(context: context, error: .payloadTooLarge(), requestId: nil)
            return
        }

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

        switch head.method {
        case .options:
            await context.writeOptions204()
            await context.cancel()
            return
        case .get:
            await handleGetMcp(head: head, body: body, context: context, clientAddress: clientAddress, now: now)
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

    private func handleGetMcp(
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

        let authResult = await authenticate(headers: head.headers, clientAddress: clientAddress)
        guard case .allow(let principal) = authResult else {
            if case .deny(let error) = authResult {
                await respondTopLevel(context: context, error: error, requestId: nil)
            }
            return
        }

        guard let sessionIdRaw = head.headers.value(for: "Mcp-Session-Id") else {
            await respondTopLevel(context: context, error: .missingSessionId(), requestId: nil)
            return
        }
        let sessionId = MCPSessionId(sessionIdRaw)
        guard await sessionStore.session(id: sessionId) != nil else {
            await respondTopLevel(context: context, error: .sessionNotFound(), requestId: nil)
            return
        }

        await sessionStore.touch(id: sessionId)

        _ = head.headers.value(for: "Last-Event-ID")
        let mcpProtocolVersion = head.headers.value(for: "mcp-protocol-version")

        let sink = TransportResponderSink(transport: self, context: context)
        let responder = MCPExchangeResponder(sink: sink, requestId: nil)

        let placeholderRequest = JsonRpcRequest(id: .null, method: "$/sse-stream", params: nil)
        let exchangeContext = MCPInboundContext(
            sessionId: sessionId,
            principal: principal,
            clientAddress: clientAddress,
            receivedAt: now,
            mcpProtocolVersion: mcpProtocolVersion
        )
        let exchange = MCPInboundExchange(
            message: .request(placeholderRequest),
            context: exchangeContext,
            responder: responder
        )
        exchangesContinuation?.yield(exchange)
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
            guard await sessionStore.session(id: candidate) != nil else {
                await respondTopLevel(context: context, error: .sessionNotFound(), requestId: requestId)
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
        exchangesContinuation?.yield(exchange)
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
            return .rateLimited()
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

    init(id: UUID, connection: NWConnection) {
        self.id = id
        self.connection = connection
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
    ) {
        if cancelled { return }
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Connection", "close")
        ]
        if let sessionId {
            headers.append(("Mcp-Session-Id", sessionId.rawValue))
        }
        headers.append(contentsOf: extraHeaders)
        headers.append(contentsOf: MCPCorsHeaders.standard)
        let head = HttpResponseHead(status: status, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: data)
        send(payload)
    }

    func writeOptions204() {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: MCPCorsHeaders.standard)
        let head = HttpResponseHead(status: .noContent, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        send(payload)
    }

    func writeNoContent() {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: MCPCorsHeaders.standard)
        let head = HttpResponseHead(status: .noContent, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        send(payload)
    }

    func writeAccepted() {
        if cancelled { return }
        var headers: [(String, String)] = [("Connection", "close")]
        headers.append(contentsOf: MCPCorsHeaders.standard)
        let head = HttpResponseHead(status: .accepted, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        send(payload)
    }

    func writeSseStreamHeaders(sessionId: MCPSessionId) {
        if cancelled { return }
        sseActive = true
        var headers: [(String, String)] = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
            ("Mcp-Session-Id", sessionId.rawValue)
        ]
        headers.append(contentsOf: MCPCorsHeaders.standard)
        let head = HttpResponseHead(status: .ok, headers: HttpHeaders(headers))
        let payload = HttpResponseEncoder.encode(head, body: nil)
        send(payload)
    }

    func writeSseFrame(_ frame: SseFrame) {
        if cancelled { return }
        let data = SseEncoder.encode(frame)
        send(data)
    }

    func writeRaw(_ data: Data) {
        if cancelled { return }
        send(data)
    }

    func cancel() {
        if cancelled { return }
        cancelled = true
        connection.cancel()
    }

    func isSseActive() -> Bool {
        sseActive
    }

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                Self.logger.debug("Send error: \(error.localizedDescription, privacy: .public)")
            }
        })
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
