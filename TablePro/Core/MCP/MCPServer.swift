//
//  MCPServer.swift
//  TablePro
//

import Foundation
import Network
import os

actor MCPServer {
    struct SessionSnapshot: Sendable, Identifiable {
        let id: String
        let clientName: String
        let clientVersion: String?
        let connectedSince: Date
        let lastActivityAt: Date
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPServer")

    private static let maxSessions = 10
    private static let idleTimeout: TimeInterval = 300
    private static let cleanupInterval: TimeInterval = 60
    private static let maxReadSize = 1_048_576
    private static let maxBufferSize = 10 * 1_024 * 1_024

    // MARK: - State

    private var listener: NWListener?
    private var sessions: [String: MCPSession] = [:]
    private var cleanupTask: Task<Void, Never>?
    private let stateCallback: @Sendable (MCPServerState) -> Void
    private var router: MCPRouter!

    private(set) var toolCallHandler: (@Sendable (String, JSONValue?, String) async throws -> MCPToolResult)?
    private(set) var resourceReadHandler: (@Sendable (String, String) async throws -> MCPResourceReadResult)?
    private(set) var sessionCleanupHandler: (@Sendable (String) async -> Void)?

    // MARK: - Initialization

    init(stateCallback: @escaping @Sendable (MCPServerState) -> Void) {
        self.stateCallback = stateCallback
        self.router = MCPRouter()
    }

    // MARK: - Handler Configuration

    func setToolCallHandler(_ handler: @escaping @Sendable (String, JSONValue?, String) async throws -> MCPToolResult) {
        self.toolCallHandler = handler
    }

    func setResourceReadHandler(_ handler: @escaping @Sendable (String, String) async throws -> MCPResourceReadResult) {
        self.resourceReadHandler = handler
    }

    func setSessionCleanupHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        self.sessionCleanupHandler = handler
    }

    // MARK: - Lifecycle

    func start(port: UInt16) throws {
        guard listener == nil else {
            Self.logger.warning("Server already running, ignoring start request")
            return
        }

        stateCallback(.starting)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 23_508)
        params.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: params)
        self.listener = newListener

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                await self.handleListenerState(state, listener: newListener)
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleNewConnection(connection)
            }
        }

        newListener.start(queue: .global(qos: .userInitiated))
        startCleanupTimer()
    }

    func stop() async {
        Self.logger.info("Stopping MCP server")

        cleanupTask?.cancel()
        cleanupTask = nil

        for (_, session) in sessions {
            await session.cancelAllTasks()
            await session.cancelSSEConnection()
        }
        sessions.removeAll()

        if let currentListener = listener {
            listener = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                currentListener.stateUpdateHandler = { state in
                    if case .cancelled = state {
                        continuation.resume()
                    }
                }
                currentListener.cancel()
            }
        }
    }

    var sessionCount: Int {
        sessions.count
    }

    func sessionSnapshots() async -> [SessionSnapshot] {
        let now = ContinuousClock.now
        var snapshots: [SessionSnapshot] = []
        for (_, session) in sessions {
            let info = await session.clientInfo
            let created = await session.createdAt
            let lastActive = await session.lastActivityAt
            let connectedElapsed = now - created
            let activeElapsed = now - lastActive
            snapshots.append(SessionSnapshot(
                id: session.id,
                clientName: info?.name ?? String(localized: "Unknown"),
                clientVersion: info?.version,
                connectedSince: Date.now - TimeInterval(connectedElapsed.components.seconds),
                lastActivityAt: Date.now - TimeInterval(activeElapsed.components.seconds)
            ))
        }
        return snapshots
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            let port = listener.port?.rawValue ?? 0
            Self.logger.info("MCP server listening on 127.0.0.1:\(port)")
            stateCallback(.running(port: port))

        case .failed(let error):
            Self.logger.error("MCP server listener failed: \(error.localizedDescription)")
            stateCallback(.failed(error.localizedDescription))
            self.listener = nil
            listener.cancel()

        case .cancelled:
            Self.logger.debug("MCP server listener cancelled")

        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task {
                    await self.readRequest(from: connection, buffer: Data())
                }
            case .failed(let error):
                Self.logger.debug("Connection failed: \(error.localizedDescription)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func readRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReadSize) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            Task {
                await self.processReceivedData(
                    connection: connection,
                    existingBuffer: buffer,
                    content: content,
                    isComplete: isComplete,
                    error: error
                )
            }
        }
    }

    private func processReceivedData(
        connection: NWConnection,
        existingBuffer: Data,
        content: Data?,
        isComplete: Bool,
        error: NWError?
    ) {
        if let error {
            Self.logger.debug("Read error: \(error.localizedDescription)")
            connection.cancel()
            return
        }

        var buffer = existingBuffer
        if let content {
            buffer.append(content)
        }

        // DoS prevention: reject requests with accumulated buffer exceeding max body size
        if buffer.count > Self.maxBufferSize {
            Self.logger.warning("Request buffer exceeds \(Self.maxBufferSize) bytes, rejecting")
            sendHTTPError(connection: connection, status: 413, message: "Request entity too large")
            return
        }

        let parseResult = MCPHTTPParser.parse(buffer)

        switch parseResult {
        case .success(let request):
            Task {
                await self.handleHTTPRequest(request, connection: connection)
            }

        case .failure(.incomplete):
            if isComplete {
                sendHTTPError(connection: connection, status: 400, message: "Incomplete request")
            } else {
                readRequest(from: connection, buffer: buffer)
            }

        case .failure(.bodyTooLarge):
            sendHTTPError(connection: connection, status: 400, message: "Request body too large")

        case .failure(let parseError):
            Self.logger.warning("Parse error: \(String(describing: parseError))")
            sendHTTPError(connection: connection, status: 400, message: "Malformed HTTP request")
        }
    }

    // MARK: - HTTP Request Handling

    private static let corsHeaders: [(String, String)] = [
        ("Access-Control-Allow-Origin", "*"),
        ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
        ("Access-Control-Allow-Headers", "Content-Type, Mcp-Session-Id, mcp-protocol-version"),
        ("Access-Control-Expose-Headers", "Mcp-Session-Id"),
        ("Access-Control-Max-Age", "86400")
    ]

    private func handleHTTPRequest(_ request: HTTPRequest, connection: NWConnection) async {
        let result = await router.route(request, server: self)

        switch result {
        case .json(let data, let sessionId):
            sendJsonResponse(connection: connection, data: data, sessionId: sessionId)

        case .sseStream(let sessionId):
            if let session = sessions[sessionId] {
                await session.cancelSSEConnection()
                await session.setSSEConnection(connection)
            }
            sendSseHeaders(connection: connection, sessionId: sessionId)

        case .accepted:
            sendResponse(connection: connection, status: 202, headers: Self.corsHeaders, body: nil)

        case .noContent:
            sendResponse(connection: connection, status: 204, headers: Self.corsHeaders, body: nil)

        case .httpError(let status, let message):
            sendHTTPError(connection: connection, status: status, message: message)
        }
    }

    // MARK: - Session Management

    func createSession() -> MCPSession? {
        guard sessions.count < Self.maxSessions else {
            Self.logger.warning("Maximum session limit reached (\(Self.maxSessions))")
            return nil
        }

        let session = MCPSession()
        sessions[session.id] = session
        Self.logger.info("Created session \(session.id) (total: \(self.sessions.count))")
        return session
    }

    func session(for sessionId: String) -> MCPSession? {
        sessions[sessionId]
    }

    func removeSession(_ sessionId: String) async {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        await session.cancelAllTasks()
        await session.cancelSSEConnection()

        // Notify external cleanup (e.g. MCPAuthGuard session approvals)
        if let cleanupHandler = sessionCleanupHandler {
            await cleanupHandler(sessionId)
        }

        Self.logger.info("Removed session \(sessionId) (total: \(self.sessions.count))")
    }

    // MARK: - Cleanup

    private func startCleanupTimer() {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.cleanupInterval))
                guard !Task.isCancelled else { break }
                await self?.cleanupIdleSessions()
            }
        }
    }

    private func cleanupIdleSessions() async {
        let now = ContinuousClock.now
        var removed: [String] = []

        for (id, session) in sessions {
            let lastActivity = await session.lastActivityAt
            let idle = now - lastActivity
            if idle > .seconds(Self.idleTimeout) {
                await session.cancelAllTasks()
                await session.cancelSSEConnection()
                sessions.removeValue(forKey: id)

                if let cleanupHandler = sessionCleanupHandler {
                    await cleanupHandler(id)
                }

                removed.append(id)
            }
        }

        if !removed.isEmpty {
            Self.logger.info("Cleaned up \(removed.count) idle session(s)")
        }
    }

    // MARK: - HTTP Response Helpers

    func sendResponse(connection: NWConnection, status: Int, headers: [(String, String)], body: Data?) {
        let statusText = MCPHTTPParser.statusText(for: status)
        let responseData = MCPHTTPParser.buildResponse(
            status: status,
            statusText: statusText,
            headers: headers,
            body: body
        )
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error {
                Self.logger.debug("Send error: \(error.localizedDescription)")
            }
            if status != 200 || headers.contains(where: { $0.0.lowercased() == "connection" && $0.1.lowercased() == "close" }) {
                connection.cancel()
            }
        })
    }

    func sendJsonResponse(connection: NWConnection, data: Data, sessionId: String?) {
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Connection", "close")
        ]
        headers.append(contentsOf: Self.corsHeaders)
        if let sessionId {
            headers.append(("Mcp-Session-Id", sessionId))
        }
        sendResponse(connection: connection, status: 200, headers: headers, body: data)
    }

    func sendSseHeaders(connection: NWConnection, sessionId: String) {
        let headerData = MCPHTTPParser.buildSSEHeaders(
            sessionId: sessionId,
            corsHeaders: Self.corsHeaders
        )
        connection.send(content: headerData, completion: .contentProcessed { error in
            if let error {
                Self.logger.debug("SSE header send error: \(error.localizedDescription)")
            }
        })
    }

    func sendSseEvent(connection: NWConnection, data: Data, eventId: String? = nil) {
        let eventData = MCPHTTPParser.buildSSEEvent(data: data, id: eventId)
        connection.send(content: eventData, completion: .contentProcessed { error in
            if let error {
                Self.logger.debug("SSE event send error: \(error.localizedDescription)")
            }
        })
    }

    func sendHTTPError(connection: NWConnection, status: Int, message: String) {
        let body: [String: String] = ["error": message]
        let data = (try? JSONEncoder().encode(body)) ?? Data()
        var headers: [(String, String)] = [
            ("Content-Type", "application/json"),
            ("Connection", "close")
        ]
        headers.append(contentsOf: Self.corsHeaders)
        sendResponse(connection: connection, status: status, headers: headers, body: data)
    }
}
