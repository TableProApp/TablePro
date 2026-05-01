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
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPServerManager")

    static let shared = MCPServerManager()

    private(set) var state: MCPServerState = .stopped
    private(set) var connectedClients: [MCPServer.SessionSnapshot] = []
    private var server: MCPServer?
    private var clientRefreshTask: Task<Void, Never>?
    private var serverGeneration: Int = 0
    private(set) var tokenStore: MCPTokenStore?
    private var tlsManager: MCPTLSManager?
    private var bridgeTokenId: UUID?
    private var internalBridgeToken: String?

    var isRunning: Bool {
        if case .running = state { return true } else { return false }
    }

    var connectedClientCount: Int {
        get async {
            guard let server else { return 0 }
            return await server.sessionCount
        }
    }

    private init() {}

    func start(port: UInt16) async {
        if server != nil {
            await stop()
        }

        serverGeneration += 1
        let generation = serverGeneration
        let newServer = MCPServer { [weak self] newState in
            Task { @MainActor in
                guard let self, self.serverGeneration == generation else { return }
                self.state = newState
            }
        }

        self.server = newServer

        let newTokenStore = MCPTokenStore()
        await newTokenStore.loadFromDisk()
        self.tokenStore = newTokenStore

        let rateLimiter = MCPRateLimiter()

        let bridge = MCPConnectionBridge()
        let authPolicy = MCPAuthPolicy()
        let toolHandler = MCPToolHandler(bridge: bridge, authPolicy: authPolicy)
        let resourceHandler = MCPResourceHandler(bridge: bridge, authPolicy: authPolicy)

        await newServer.setTokenStore(newTokenStore)
        await newServer.setRateLimiter(rateLimiter)

        await newServer.setToolCallHandler { name, arguments, sessionId, token in
            try await toolHandler.handleToolCall(name: name, arguments: arguments, sessionId: sessionId, token: token)
        }
        await newServer.setResourceReadHandler { uri, sessionId in
            try await resourceHandler.handleResourceRead(uri: uri, sessionId: sessionId)
        }
        await newServer.setSessionCleanupHandler { sessionId in
            await authPolicy.clearSession(sessionId)
        }

        let protocolHandler = MCPProtocolHandler(
            server: newServer,
            tokenStore: newTokenStore,
            rateLimiter: rateLimiter
        )
        let exchangeHandler = IntegrationsExchangeHandler.live()
        let router = MCPRouter(routes: [protocolHandler, exchangeHandler])
        await newServer.setRouter(router)

        let bridgeResult = await newTokenStore.generate(
            name: MCPTokenStore.stdioBridgeTokenName,
            permissions: .fullAccess
        )
        self.bridgeTokenId = bridgeResult.token.id
        self.internalBridgeToken = bridgeResult.plaintext

        do {
            let settings = AppSettingsManager.shared.mcp

            var tlsIdentity: SecIdentity?
            if settings.allowRemoteConnections {
                let manager = MCPTLSManager()
                self.tlsManager = manager
                do {
                    tlsIdentity = try await manager.loadOrGenerate()
                } catch {
                    Self.logger.error("Failed to generate TLS certificate: \(error.localizedDescription)")
                    state = .failed("TLS certificate generation failed")
                    return
                }
            }

            try await newServer.start(
                port: port,
                allowRemoteAccess: settings.allowRemoteConnections,
                tlsIdentity: tlsIdentity
            )
            let certFingerprint = await tlsManager?.fingerprint
            writeHandshakeFile(port: port, tlsCertFingerprint: certFingerprint)
            startClientRefresh()
            MCPAuditLogger.logServerStarted(
                port: port,
                remoteAccess: settings.allowRemoteConnections,
                tlsEnabled: tlsIdentity != nil
            )
        } catch {
            Self.logger.error("Failed to start MCP server: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            if let bridgeId = bridgeTokenId {
                await tokenStore?.delete(tokenId: bridgeId)
                bridgeTokenId = nil
            }
            server = nil
            self.tokenStore = nil
            self.tlsManager = nil
            self.internalBridgeToken = nil
        }
    }

    func stop() async {
        stopClientRefresh()
        deleteHandshakeFile()
        MCPAuditLogger.logServerStopped()
        guard let server else { return }
        await server.stop()
        if let bridgeId = bridgeTokenId {
            await tokenStore?.delete(tokenId: bridgeId)
            bridgeTokenId = nil
        }
        self.server = nil
        self.tokenStore = nil
        self.tlsManager = nil
        self.internalBridgeToken = nil
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
                Self.logger.error("Lazy start failed to allocate port: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
                return
            }
        }

        await start(port: chosenPort)
    }

    func disconnectClient(_ sessionId: String) async {
        await server?.removeSession(sessionId)
        await refreshClients()
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
        guard let server else {
            connectedClients = []
            return
        }
        connectedClients = await server.sessionSnapshots()
    }

    private static let handshakeDirectoryPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/TablePro"
    }()

    private static let handshakeFilePath: String = {
        "\(handshakeDirectoryPath)/mcp-handshake.json"
    }()

    private func writeHandshakeFile(port: UInt16, tlsCertFingerprint: String? = nil) {
        guard let bridgeToken = internalBridgeToken else { return }

        let settings = AppSettingsManager.shared.mcp
        var handshake: [String: Any] = [
            "port": Int(port),
            "token": bridgeToken,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "protocolVersion": "2025-03-26",
            "tls": settings.allowRemoteConnections
        ]
        if let tlsCertFingerprint {
            handshake["tlsCertFingerprint"] = tlsCertFingerprint
        }

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

            let data = try JSONSerialization.data(withJSONObject: handshake, options: [.sortedKeys])
            let url = URL(fileURLWithPath: Self.handshakeFilePath)
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.handshakeFilePath
            )

            Self.logger.info("Wrote MCP handshake file at \(Self.handshakeFilePath)")
        } catch {
            Self.logger.error("Failed to write MCP handshake file: \(error.localizedDescription)")
        }
    }

    private func deleteHandshakeFile() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: Self.handshakeFilePath) else { return }

        do {
            try fileManager.removeItem(atPath: Self.handshakeFilePath)
            Self.logger.info("Deleted MCP handshake file")
        } catch {
            Self.logger.error("Failed to delete MCP handshake file: \(error.localizedDescription)")
        }
    }
}
