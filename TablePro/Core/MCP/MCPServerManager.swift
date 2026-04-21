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
    private var server: MCPServer?

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

        let newServer = MCPServer { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
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

        do {
            try await newServer.start(port: port)
        } catch {
            Self.logger.error("Failed to start MCP server: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            server = nil
        }
    }

    func stop() async {
        guard let server else { return }
        await server.stop()
        self.server = nil
        state = .stopped
    }

    func restart(port: UInt16) async {
        await stop()
        await start(port: port)
    }
}
