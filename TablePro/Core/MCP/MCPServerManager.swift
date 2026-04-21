//
//  MCPServerManager.swift
//  TablePro
//

import Foundation
import os

/// MCP server lifecycle state
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

        // Wire tool and resource handlers
        let bridge = MCPConnectionBridge()
        let authGuard = MCPAuthGuard()
        let toolHandler = MCPToolHandler(bridge: bridge, authGuard: authGuard)
        let resourceHandler = MCPResourceHandler(bridge: bridge)

        await newServer.setToolCallHandler { name, arguments, sessionId in
            try await toolHandler.handleToolCall(name: name, arguments: arguments, sessionId: sessionId)
        }
        await newServer.setResourceReadHandler { uri, sessionId in
            try await resourceHandler.handleResourceRead(uri: uri, sessionId: sessionId)
        }
        await newServer.setSessionCleanupHandler { sessionId in
            await authGuard.clearSession(sessionId)
        }

        do {
            try await newServer.start(port: port)
            startClientRefresh()
        } catch {
            Self.logger.error("Failed to start MCP server: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            server = nil
        }
    }

    func stop() async {
        stopClientRefresh()
        guard let server else { return }
        await server.stop()
        self.server = nil
        state = .stopped
    }

    func restart(port: UInt16) async {
        await stop()
        await start(port: port)
    }

    func disconnectClient(_ sessionId: String) async {
        await server?.removeSession(sessionId)
        await refreshClients()
    }

    // MARK: - Client Refresh

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
}
