import Foundation
import os
import Security

enum MCPServerState: Sendable, Equatable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)
}

@MainActor @Observable
final class MCPServerManager {
    struct SessionSnapshot: Sendable, Identifiable {
        let id: String
        let clientName: String
        let clientVersion: String?
        let connectedSince: Date
        let lastActivityAt: Date
        let tokenName: String?
        let remoteAddress: String?
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPServerManager")

    static let shared = MCPServerManager()

    private(set) var state: MCPServerState = .stopped
    private(set) var connectedClients: [SessionSnapshot] = []
    private(set) var tokenStore: MCPTokenStore?

    private var transport: MCPHttpServerTransport?
    private var dispatcher: MCPProtocolDispatcher?
    private var sessionStore: MCPSessionStore?
    private var rateLimiter: MCPRateLimiter?
    private var dispatchTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var sessionEventsTask: Task<Void, Never>?
    private var clientRefreshTask: Task<Void, Never>?
    private var tlsManager: MCPTLSManager?
    private var bridgeTokenId: UUID?
    private var internalBridgeToken: String?
    private var serverGeneration: Int = 0
    private var revocationObserverId: UUID?

    var isRunning: Bool {
        if case .running = state { return true } else { return false }
    }

    var connectedClientCount: Int {
        get async {
            guard let sessionStore else { return 0 }
            return await sessionStore.count()
        }
    }

    private init() {}

    func start(port: UInt16) async {
        if transport != nil {
            await stop()
        }

        Self.removeStaleHandshakeFileIfNeeded()

        serverGeneration += 1
        let generation = serverGeneration
        state = .starting

        let newTokenStore = MCPTokenStore()
        await newTokenStore.loadFromDisk()
        tokenStore = newTokenStore

        let bridgeResult = await newTokenStore.generate(
            name: MCPTokenStore.stdioBridgeTokenName,
            permissions: .fullAccess
        )
        bridgeTokenId = bridgeResult.token.id
        internalBridgeToken = bridgeResult.plaintext

        let settings = AppSettingsManager.shared.mcp
        let configuration: MCPHttpServerConfiguration
        do {
            configuration = try await makeConfiguration(port: port, settings: settings)
        } catch {
            Self.logger.error("MCP TLS configuration failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("TLS certificate generation failed")
            await cleanupBridgeToken()
            tokenStore = nil
            return
        }

        let newSessionStore = MCPSessionStore(policy: .standard)
        await newSessionStore.startCleanup()
        sessionStore = newSessionStore

        let newRateLimiter = MCPRateLimiter()
        rateLimiter = newRateLimiter

        let authenticator = MCPBearerTokenAuthenticator(
            tokenStore: newTokenStore,
            rateLimiter: newRateLimiter
        )

        let newTransport = MCPHttpServerTransport(
            configuration: configuration,
            sessionStore: newSessionStore,
            authenticator: authenticator
        )
        transport = newTransport

        let progressSink = TransportProgressSink(transport: newTransport)
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        let handlers: [any MCPMethodHandler] = [
            InitializeHandler(),
            PingHandler(),
            ToolsListHandler(),
            ToolsCallHandler(services: services),
            ResourcesListHandler(services: services),
            ResourcesReadHandler(services: services),
            ResourcesTemplatesListHandler(),
            PromptsListHandler(),
            PromptsGetHandler(),
            LoggingSetLevelHandler(),
            CompletionCompleteHandler()
        ]

        let newDispatcher = MCPProtocolDispatcher(
            handlers: handlers,
            sessionStore: newSessionStore,
            progressSink: progressSink
        )
        dispatcher = newDispatcher

        startDispatchLoop(transport: newTransport, dispatcher: newDispatcher, generation: generation)
        startStateLoop(transport: newTransport, generation: generation)
        startSessionEventsLoop(sessionStore: newSessionStore, generation: generation)
        await registerRevocationObserver(
            tokenStore: newTokenStore,
            sessionStore: newSessionStore,
            dispatcher: newDispatcher,
            generation: generation
        )

        do {
            try await newTransport.start()
            startClientRefresh()
            MCPAuditLogger.logServerStarted(
                port: port,
                remoteAccess: settings.allowRemoteConnections,
                tlsEnabled: configuration.tls != nil
            )
        } catch {
            Self.logger.error("Failed to start MCP server: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            await teardown()
        }
    }

    func stop() async {
        stopClientRefresh()
        deleteHandshakeFile()
        MCPAuditLogger.logServerStopped()
        await teardown()
        state = .stopped
    }

    func restart(port: UInt16) async {
        await stop()
        await start(port: port)
    }

    func lazyStart() async {
        if case .running = state { return }
        if case .starting = state { return }

        let settings = AppSettingsManager.shared.mcp
        let preferredPort = UInt16(clamping: settings.port)

        let chosenPort: UInt16
        if preferredPort > 0, MCPPortAllocator.isFree(port: preferredPort) {
            chosenPort = preferredPort
        } else {
            do {
                chosenPort = try MCPPortAllocator.findFreePort(in: 51_000...52_000)
            } catch {
                Self.logger.error("Lazy start failed to allocate port: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                return
            }
        }

        await start(port: chosenPort)
    }

    func disconnectClient(_ sessionId: String) async {
        guard let sessionStore else { return }
        await sessionStore.terminate(id: MCPSessionId(sessionId), reason: .clientRequested)
        await refreshClients()
    }

    private func makeConfiguration(
        port: UInt16,
        settings: MCPSettings
    ) async throws -> MCPHttpServerConfiguration {
        if settings.allowRemoteConnections {
            let manager = MCPTLSManager()
            tlsManager = manager
            let identity = try await manager.loadOrGenerate()
            let tls = MCPTLSConfiguration(identity: identity)
            return .remote(port: port, tls: tls)
        }
        return .loopback(port: port)
    }

    private func startDispatchLoop(
        transport: MCPHttpServerTransport,
        dispatcher: MCPProtocolDispatcher,
        generation: Int
    ) {
        dispatchTask?.cancel()
        dispatchTask = Task { [weak self] in
            for await exchange in transport.exchanges {
                guard let self else { return }
                guard await self.isCurrentGeneration(generation) else { return }
                Task { await dispatcher.dispatch(exchange) }
            }
        }
    }

    private func startStateLoop(transport: MCPHttpServerTransport, generation: Int) {
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await transportState in transport.listenerState {
                guard let self else { return }
                await self.applyTransportState(transportState, generation: generation)
            }
        }
    }

    private func startSessionEventsLoop(sessionStore: MCPSessionStore, generation: Int) {
        sessionEventsTask?.cancel()
        sessionEventsTask = Task { [weak self] in
            let stream = await sessionStore.events
            for await event in stream {
                guard let self else { return }
                guard await self.isCurrentGeneration(generation) else { return }
                Self.logger.debug("Session event: \(String(describing: event), privacy: .public)")
                await self.refreshClients()
            }
        }
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        serverGeneration == generation
    }

    private func registerRevocationObserver(
        tokenStore: MCPTokenStore,
        sessionStore: MCPSessionStore,
        dispatcher: MCPProtocolDispatcher,
        generation: Int
    ) async {
        let observerId = await tokenStore.addRevocationObserver { [weak self] tokenIdString in
            guard let tokenId = UUID(uuidString: tokenIdString) else { return }
            guard let self else { return }
            await self.handleTokenRevoked(
                tokenId: tokenId,
                sessionStore: sessionStore,
                dispatcher: dispatcher,
                generation: generation
            )
        }
        revocationObserverId = observerId
    }

    private func handleTokenRevoked(
        tokenId: UUID,
        sessionStore: MCPSessionStore,
        dispatcher: MCPProtocolDispatcher,
        generation: Int
    ) async {
        guard isCurrentGeneration(generation) else { return }
        let cancelledSessions = await dispatcher.cancelInflight(matchingTokenId: tokenId)
        let extraSessions = await sessionStore.sessionIds(forPrincipalTokenId: tokenId)
        let toTerminate = Set(cancelledSessions + extraSessions)
        for sessionId in toTerminate {
            await sessionStore.terminate(id: sessionId, reason: .tokenRevoked)
        }
        if !toTerminate.isEmpty {
            Self.logger.info(
                "Token \(tokenId.uuidString, privacy: .public) revoked: cancelled \(toTerminate.count, privacy: .public) session(s)"
            )
        }
    }

    private func applyTransportState(_ transportState: MCPHttpServerState, generation: Int) {
        guard isCurrentGeneration(generation) else { return }
        switch transportState {
        case .idle:
            state = .stopped
        case .starting:
            state = .starting
        case .running(let port):
            state = .running(port: port)
            Task { [weak self] in
                guard let self else { return }
                let fingerprint = await self.tlsManager?.fingerprint
                self.writeHandshakeFile(port: port, tlsCertFingerprint: fingerprint)
            }
        case .stopped:
            state = .stopped
        case .failed(let reason):
            state = .failed(reason)
        }
    }

    private func teardown() async {
        dispatchTask?.cancel()
        dispatchTask = nil
        stateTask?.cancel()
        stateTask = nil
        sessionEventsTask?.cancel()
        sessionEventsTask = nil

        if let transport {
            await transport.stop()
        }
        transport = nil

        if let sessionStore {
            await sessionStore.shutdown(reason: .serverShutdown)
        }
        sessionStore = nil

        dispatcher = nil
        rateLimiter = nil
        tlsManager = nil

        if let observerId = revocationObserverId, let store = tokenStore {
            await store.removeRevocationObserver(observerId)
            revocationObserverId = nil
        }
        await cleanupBridgeToken()
        tokenStore = nil
        connectedClients = []
    }

    private func cleanupBridgeToken() async {
        if let bridgeId = bridgeTokenId {
            await tokenStore?.delete(tokenId: bridgeId)
            bridgeTokenId = nil
        }
        internalBridgeToken = nil
    }

    private func startClientRefresh() {
        clientRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshClients()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopClientRefresh() {
        clientRefreshTask?.cancel()
        clientRefreshTask = nil
        connectedClients = []
    }

    private func refreshClients() async {
        guard let sessionStore else {
            connectedClients = []
            return
        }
        let snapshots = await collectSessionSnapshots(from: sessionStore)
        connectedClients = snapshots
    }

    private func collectSessionSnapshots(from store: MCPSessionStore) async -> [SessionSnapshot] {
        await store.snapshotsForUI()
    }

    private static let handshakeDirectoryPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/TablePro"
    }()

    private static let handshakeFilePath: String = {
        "\(handshakeDirectoryPath)/mcp-handshake.json"
    }()

    private struct HandshakeFilePayload: Codable {
        let port: Int
        let token: String
        let pid: Int32
        let protocolVersion: String
        let tls: Bool
        let tlsCertFingerprint: String?
    }

    private func writeHandshakeFile(port: UInt16, tlsCertFingerprint: String? = nil) {
        guard let bridgeToken = internalBridgeToken else { return }

        let settings = AppSettingsManager.shared.mcp
        let payload = HandshakeFilePayload(
            port: Int(port),
            token: bridgeToken,
            pid: ProcessInfo.processInfo.processIdentifier,
            protocolVersion: InitializeHandler.supportedProtocolVersion,
            tls: settings.allowRemoteConnections,
            tlsCertFingerprint: tlsCertFingerprint
        )

        let fileManager = FileManager.default
        let directory = Self.handshakeDirectoryPath

        do {
            if !fileManager.fileExists(atPath: directory) {
                try fileManager.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory
                )
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            let url = URL(fileURLWithPath: Self.handshakeFilePath)
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.handshakeFilePath
            )

            Self.logger.info("Wrote MCP handshake file at \(Self.handshakeFilePath, privacy: .public)")
        } catch {
            Self.logger.error("Failed to write MCP handshake file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func removeStaleHandshakeFileIfNeeded() {
        let path = handshakeFilePath
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        guard let payload = try? JSONDecoder().decode(HandshakeFilePayload.self, from: data) else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier
        if payload.pid == currentPid { return }
        if kill(payload.pid, 0) == 0 { return }
        try? FileManager.default.removeItem(atPath: path)
        Self.logger.info("Removed stale MCP handshake from PID \(payload.pid, privacy: .public)")
    }

    private func deleteHandshakeFile() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: Self.handshakeFilePath) else { return }

        do {
            try fileManager.removeItem(atPath: Self.handshakeFilePath)
            Self.logger.info("Deleted MCP handshake file")
        } catch {
            Self.logger.error("Failed to delete MCP handshake file: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct TransportProgressSink: MCPProgressSink {
    let transport: MCPHttpServerTransport

    func sendNotification(_ notification: JsonRpcNotification, toSession sessionId: MCPSessionId) async {
        await transport.sendNotification(notification, toSession: sessionId)
    }
}

private extension MCPSessionStore {
    func snapshotsForUI() async -> [MCPServerManager.SessionSnapshot] {
        var result: [MCPServerManager.SessionSnapshot] = []
        for session in await allSessions() {
            let snapshot = await session.snapshot()
            let info = snapshot.clientInfo
            result.append(MCPServerManager.SessionSnapshot(
                id: snapshot.id.rawValue,
                clientName: info?.name ?? String(localized: "Unknown"),
                clientVersion: info?.version,
                connectedSince: snapshot.createdAt,
                lastActivityAt: snapshot.lastActivityAt,
                tokenName: nil,
                remoteAddress: nil
            ))
        }
        return result
    }
}
