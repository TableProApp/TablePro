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
    private var sseWriters: [UUID: MCPSseWriter] = [:]
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
            bufferingPolicy: .bufferingOldest(1_024)
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
            Self.logger.error("Remote access requested without TLS, refusing to start")
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

        for (_, writer) in sseWriters {
            await writer.stop()
        }
        sseWriters.removeAll()

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
              let writer = sseWriters[connectionId] else {
            return
        }

        let message = JsonRpcMessage.notification(notification)
        guard let data = try? JsonRpcCodec.encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        await writer.writeFrame(SseFrame(data: text))
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
        guard let connectionId = sseConnectionsBySession.removeValue(forKey: sessionId) else {
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

        if let writer = sseWriters.removeValue(forKey: connectionId) {
            await writer.writeComment(comment)
            await writer.stop()
        } else if let context = connections[connectionId] {
            await context.writeRaw(Data("\u{003A} \(comment)\n\n".utf8))
            await context.cancel()
        }
        connections.removeValue(forKey: connectionId)
    }

    private func handleNewConnection(_ connection: NWConnection) async {
        let connectionId = UUID()
        Self.logger.debug("Accepted connection \(connectionId, privacy: .public)")
        let context = HttpConnectionContext(id: connectionId, connection: connection)
        connections[connectionId] = context
        let router = makeRouter()
        await context.start { [weak self] data in
            guard let self else { return }
            await self.handleReceivedData(connectionId: connectionId, data: data, router: router)
        } onClosed: { [weak self] in
            guard let self else { return }
            await self.removeConnection(connectionId: connectionId)
        }
    }

    private func makeRouter() -> MCPHttpRequestRouter {
        let exchangesContinuation = self.exchangesContinuation
        let transport = self
        return MCPHttpRequestRouter(
            configuration: configuration,
            sessionStore: sessionStore,
            authenticator: authenticator,
            clock: clock,
            emitInbound: { exchange in
                exchangesContinuation.yield(exchange)
            },
            startSse: { connectionId, sessionId, context in
                await transport.attachSseWriter(connectionId: connectionId, sessionId: sessionId, context: context)
            },
            makeResponderSink: { context in
                TransportResponderSink(transport: transport, context: context)
            }
        )
    }

    private func removeConnection(connectionId: UUID) async {
        connections.removeValue(forKey: connectionId)
        if let writer = sseWriters.removeValue(forKey: connectionId) {
            await writer.stop()
        }
        let pairs = sseConnectionsBySession.filter { $0.value == connectionId }
        for (sessionId, _) in pairs {
            sseConnectionsBySession.removeValue(forKey: sessionId)
        }
    }

    private func handleReceivedData(connectionId: UUID, data: Data, router: MCPHttpRequestRouter) async {
        guard let context = connections[connectionId] else { return }

        let parseResult: HttpRequestParseResult
        do {
            parseResult = try HttpRequestParser.parse(data)
        } catch HttpRequestParseError.bodyTooLarge {
            await respondParseFailure(context: context, status: .payloadTooLarge)
            return
        } catch HttpRequestParseError.headerTooLarge {
            await respondParseFailure(context: context, status: .payloadTooLarge)
            return
        } catch {
            await respondParseFailure(context: context, status: .badRequest, detail: "Malformed HTTP")
            return
        }

        switch parseResult {
        case .incomplete:
            return
        case .complete(let head, let body, _):
            await context.markRequestComplete()
            await router.dispatch(head: head, body: body, context: context)
        }
    }

    private func respondParseFailure(context: HttpConnectionContext, status: HttpStatus, detail: String? = nil) async {
        let error: MCPProtocolError
        if status.code == HttpStatus.payloadTooLarge.code {
            error = .payloadTooLarge()
        } else {
            error = .invalidRequest(detail: detail ?? "Bad request")
        }
        let envelope = error.toJsonRpcErrorResponse(id: nil)
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        await context.writeJsonResponse(
            data: data,
            status: error.httpStatus,
            sessionId: nil,
            extraHeaders: error.extraHeaders
        )
        await context.cancel()
    }

    fileprivate func attachSseWriter(
        connectionId: UUID,
        sessionId: MCPSessionId,
        context: HttpConnectionContext
    ) async {
        if let previous = sseConnectionsBySession[sessionId], previous != connectionId {
            if let oldWriter = sseWriters.removeValue(forKey: previous) {
                await oldWriter.stop()
            } else if let oldContext = connections[previous] {
                await oldContext.cancel()
            }
            connections.removeValue(forKey: previous)
        }
        let writer = MCPSseWriter(context: context)
        sseWriters[connectionId] = writer
        sseConnectionsBySession[sessionId] = connectionId
        await writer.startStream(sessionId: sessionId)
    }

    fileprivate func registerSseConnection(connectionId: UUID, sessionId: MCPSessionId) async {
        guard let context = connections[connectionId] else { return }
        await attachSseWriter(connectionId: connectionId, sessionId: sessionId, context: context)
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
