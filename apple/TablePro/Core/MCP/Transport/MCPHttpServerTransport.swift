import Foundation
import Network
import os
import TableProMCP

public enum MCPHttpServerState: Sendable, Equatable {
    case idle
    case starting
    case running(port: UInt16)
    case stopped
    case failed(reason: String)
}

public actor MCPHttpServerTransport {
    // Each listener has its own connection cap, so connections held open over TCP never refuse the socket.
    private enum Listener {
        case tcp
        case unixSocket
    }

    private struct OpenConnection {
        let context: HttpConnectionContext
        let listener: Listener
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpServer")
    private static let readyTimeout: Duration = .seconds(15)
    private static let exchangeBufferSize = 1_024

    private let configuration: MCPHttpServerConfiguration
    private let authenticator: any MCPAuthenticator
    private let pairingService: MCPPairingService
    private let clock: any MCPClock
    private let allowedSocketPeerUid: uid_t

    private var listener: NWListener?
    private var socketListener: MCPUnixSocketListener?
    private var connections: [UUID: OpenConnection] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var currentState: MCPHttpServerState = .idle
    private var boundPort: UInt16 = 0

    nonisolated public let exchanges: AsyncStream<MCPInboundExchange>
    nonisolated private let exchangesContinuation: AsyncStream<MCPInboundExchange>.Continuation

    nonisolated public let listenerState: AsyncStream<MCPHttpServerState>
    nonisolated private let stateContinuation: AsyncStream<MCPHttpServerState>.Continuation

    init(
        configuration: MCPHttpServerConfiguration,
        authenticator: any MCPAuthenticator,
        pairingService: MCPPairingService,
        clock: any MCPClock = MCPSystemClock(),
        allowedSocketPeerUid: uid_t = getuid()
    ) {
        self.configuration = configuration
        self.authenticator = authenticator
        self.pairingService = pairingService
        self.clock = clock
        self.allowedSocketPeerUid = allowedSocketPeerUid

        let (exchanges, exchangesContinuation) = AsyncStream<MCPInboundExchange>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.exchangeBufferSize)
        )
        self.exchanges = exchanges
        self.exchangesContinuation = exchangesContinuation

        let (listenerState, stateContinuation) = AsyncStream<MCPHttpServerState>.makeStream()
        self.listenerState = listenerState
        self.stateContinuation = stateContinuation
    }

    public var state: MCPHttpServerState {
        currentState
    }

    public var listeningPort: UInt16? {
        guard case .running(let port) = currentState else { return nil }
        return port
    }

    public func start() async throws {
        guard listener == nil else {
            Self.logger.warning("start() called while listener already exists")
            throw MCPHttpServerError.alreadyStarted
        }

        Self.logger.info("Starting MCP HTTP server on loopback port \(self.configuration.port, privacy: .public)")
        emitState(.starting)

        let newListener: NWListener
        do {
            newListener = try NWListener(using: makeParameters())
        } catch {
            emitState(.failed(reason: error.localizedDescription))
            throw MCPHttpServerError.bindFailed(reason: error.localizedDescription)
        }
        listener = newListener

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleListenerState(state) }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.handleNewConnection(connection) }
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyContinuation = continuation
                readyTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.readyTimeout)
                    await self?.handleReadyTimeout()
                }
                newListener.start(queue: .global(qos: .userInitiated))
            }
        } catch {
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            emitState(.failed(reason: error.localizedDescription))
            newListener.cancel()
            listener = nil
            throw MCPHttpServerError.bindFailed(reason: error.localizedDescription)
        }

        do {
            try startSocketListener()
        } catch {
            Self.logger.error("MCP Unix socket listener failed: \(error.publicLogShape, privacy: .public)")
            emitState(.failed(reason: error.localizedDescription))
            throw MCPHttpServerError.bindFailed(reason: error.localizedDescription)
        }
    }

    private func startSocketListener() throws {
        guard let path = configuration.socketPath else { return }
        let socketListener = MCPUnixSocketListener(path: path, allowedPeerUid: allowedSocketPeerUid) { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.handleNewStream(connection, from: .unixSocket) }
        }
        try socketListener.start()
        self.socketListener = socketListener
        Self.logger.info("MCP server listening on its Unix socket")
    }

    public func stop() async {
        Self.logger.info("Stopping MCP HTTP server")

        resumeReady(with: .failure(MCPHttpServerError.bindFailed(reason: "stop() called before listener ready")))

        socketListener?.stop()
        socketListener = nil

        for connection in connections.values {
            await connection.context.close()
        }
        connections.removeAll()

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

    private func makeParameters() -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? configuration.port
            boundPort = port
            Self.logger.info("MCP HTTP server listening on port \(port, privacy: .public)")
            emitState(.running(port: port))
            resumeReady(with: .success(()))

        case .failed(let error):
            Self.logger.error("MCP HTTP listener failed: \(error.publicLogShape, privacy: .public)")
            emitState(.failed(reason: error.localizedDescription))
            listener?.cancel()
            listener = nil
            resumeReady(with: .failure(error))

        case .cancelled:
            Self.logger.debug("MCP HTTP listener cancelled")
            resumeReady(with: .failure(MCPHttpServerError.bindFailed(reason: "listener cancelled before ready")))

        default:
            break
        }
    }

    private func resumeReady(with result: Result<Void, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        continuation.resume(with: result)
    }

    private func handleReadyTimeout() {
        guard readyContinuation != nil else { return }
        Self.logger.error("MCP HTTP listener did not reach .ready within timeout")
        resumeReady(with: .failure(MCPHttpServerError.bindFailed(reason: "listener startup timed out")))
    }

    private func emitState(_ state: MCPHttpServerState) {
        currentState = state
        stateContinuation.yield(state)
    }

    private func handleNewConnection(_ connection: NWConnection) async {
        await handleNewStream(MCPNetworkByteStream(connection: connection), from: .tcp)
    }

    private func handleNewStream(_ stream: any MCPByteStream, from listener: Listener) async {
        let connectionId = UUID()
        let context = HttpConnectionContext(
            id: connectionId,
            stream: stream,
            limits: configuration.limits
        )

        let openOnListener = connections.values.filter { $0.listener == listener }.count
        guard openOnListener < configuration.limits.maxConcurrentConnections else {
            Self.logger.warning("Refusing connection \(connectionId, privacy: .public): connection limit reached")
            await context.rejectOverCapacity()
            return
        }

        connections[connectionId] = OpenConnection(context: context, listener: listener)
        let router = makeRouter()
        await context.start { [weak self] request in
            guard let self else { return }
            await self.handleRequest(connectionId: connectionId, request: request, router: router)
        } onClosed: { [weak self] in
            await self?.removeConnection(connectionId: connectionId)
        }
    }

    private func handleRequest(
        connectionId: UUID,
        request: HttpParsedRequest,
        router: MCPHttpRequestRouter
    ) async {
        guard let context = connections[connectionId]?.context else { return }
        await router.dispatch(request: request, context: context)
    }

    private func removeConnection(connectionId: UUID) {
        connections.removeValue(forKey: connectionId)
    }

    private func makeRouter() -> MCPHttpRequestRouter {
        let continuation = exchangesContinuation
        return MCPHttpRequestRouter(
            authenticator: authenticator,
            pairingService: pairingService,
            clock: clock,
            boundPort: boundPort == 0 ? configuration.port : boundPort,
            emitInbound: { exchange in
                continuation.yield(exchange)
            }
        )
    }
}

struct MCPHttpResponderSink: MCPResponderSink {
    let context: HttpConnectionContext

    func writeJson(_ data: Data, status: HttpStatus, extraHeaders: [(String, String)]) async {
        await context.writeJsonResponse(data: data, status: status, extraHeaders: extraHeaders)
    }

    func writeAccepted() async {
        await context.writeAccepted()
    }

    func beginSseStream() async {
        await context.beginSseStream()
    }

    func writeSseFrame(_ frame: SseFrame) async {
        await context.writeSseFrame(frame)
    }

    func closeConnection() async {
        await context.completeResponse()
    }

    func isClosed() async -> Bool {
        await context.isClosed()
    }
}
