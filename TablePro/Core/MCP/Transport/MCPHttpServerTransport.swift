import Foundation
import Network
import os

public enum MCPHttpServerState: Sendable, Equatable {
    case idle
    case starting
    case running(port: UInt16)
    case stopped
    case failed(reason: String)
}

public actor MCPHttpServerTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.HttpServer")
    private static let readyTimeout: Duration = .seconds(15)
    private static let exchangeBufferSize = 1_024

    private let configuration: MCPHttpServerConfiguration
    private let authenticator: any MCPAuthenticator
    private let clock: any MCPClock

    private var listener: NWListener?
    private var connections: [UUID: HttpConnectionContext] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var currentState: MCPHttpServerState = .idle
    private var boundPort: UInt16 = 0

    nonisolated public let exchanges: AsyncStream<MCPInboundExchange>
    nonisolated private let exchangesContinuation: AsyncStream<MCPInboundExchange>.Continuation

    nonisolated public let listenerState: AsyncStream<MCPHttpServerState>
    nonisolated private let stateContinuation: AsyncStream<MCPHttpServerState>.Continuation

    public init(
        configuration: MCPHttpServerConfiguration,
        authenticator: any MCPAuthenticator,
        clock: any MCPClock = MCPSystemClock()
    ) {
        self.configuration = configuration
        self.authenticator = authenticator
        self.clock = clock

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
    }

    public func stop() async {
        Self.logger.info("Stopping MCP HTTP server")

        resumeReady(with: .failure(MCPHttpServerError.bindFailed(reason: "stop() called before listener ready")))

        for (_, context) in connections {
            await context.close()
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
            Self.logger.error("MCP HTTP listener failed: \(error.localizedDescription, privacy: .public)")
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
        let connectionId = UUID()
        let context = HttpConnectionContext(
            id: connectionId,
            connection: connection,
            limits: configuration.limits
        )

        guard connections.count < configuration.limits.maxConcurrentConnections else {
            Self.logger.warning("Refusing connection \(connectionId, privacy: .public): connection limit reached")
            await context.rejectOverCapacity()
            return
        }

        connections[connectionId] = context
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
        guard let context = connections[connectionId] else { return }
        await router.dispatch(request: request, context: context)
    }

    private func removeConnection(connectionId: UUID) {
        connections.removeValue(forKey: connectionId)
    }

    private func makeRouter() -> MCPHttpRequestRouter {
        let continuation = exchangesContinuation
        return MCPHttpRequestRouter(
            authenticator: authenticator,
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
