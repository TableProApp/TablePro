//
//  MCPRemoteToolCoordinator.swift
//  TablePro
//

import Foundation
import os

/// Which sessions have a server's tools registered, and the client session behind them.
///
/// Registration is reference-counted by session, because two sessions on two allowed connections
/// share one set of registry entries: unregistering on the first session's end would take the tools
/// out from under the second one mid-turn. The last session to leave is what closes the transport.
@MainActor
internal final class MCPRemoteToolCoordinator {
    internal static let shared = MCPRemoteToolCoordinator()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MCPRemoteTools")

    private struct Registration {
        let client: MCPClientSession
        var toolNames: Set<String>
        var authorizingSessions: Set<UUID>
    }

    private var registrations: [UUID: Registration] = [:]

    private let store: MCPServerStore
    private let registry: ChatToolRegistry

    internal init(store: MCPServerStore = .shared, registry: ChatToolRegistry = .shared) {
        self.store = store
        self.registry = registry
    }

    /// Connects every server this session's connection allows and registers their tools.
    ///
    /// Failures are per server and logged, not thrown. One unreachable server must not stop a session
    /// from starting, and the model finds out about a server that never listed its tools by not being
    /// offered them.
    internal func attach(session: AgentSession) async {
        let allowed = store.servers(allowedFor: session.connectionId)
        for configuration in allowed {
            await attach(sessionId: session.id, to: configuration)
        }
    }

    private func attach(sessionId: UUID, to configuration: MCPServerConfiguration) async {
        if var existing = registrations[configuration.id] {
            existing.authorizingSessions.insert(sessionId)
            registrations[configuration.id] = existing
            return
        }
        guard let client = MCPClientSession.make(configuration: configuration, store: store) else {
            Self.logger.info(
                "Skipping MCP server \(configuration.id, privacy: .public): no credential in the Keychain"
            )
            return
        }
        registrations[configuration.id] = Registration(
            client: client,
            toolNames: [],
            authorizingSessions: [sessionId]
        )

        let tools: [MCPRemoteTool]
        do {
            tools = try await client.listTools()
        } catch {
            Self.logger.error(
                """
                MCP server \(configuration.id, privacy: .public) did not list its tools: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            await detachAll(serverId: configuration.id)
            return
        }

        /// The listing was awaited, so the registration this is about to fill may be gone: the last
        /// session holding it can end while a slow server is still answering. Registering the tools
        /// then would leave adapters in the registry that nothing tracks the names of and that call
        /// a transport already closed, so the whole batch is dropped instead.
        guard registrations[configuration.id] != nil else {
            Self.logger.info(
                "MCP server \(configuration.id, privacy: .public) listed its tools after the last session left"
            )
            await client.close()
            return
        }

        var registered: Set<String> = []
        for tool in tools {
            let adapter = MCPRemoteToolAdapter(server: configuration, tool: tool) { remoteName, arguments in
                try await client.callTool(name: remoteName, arguments: arguments)
            }
            guard registry.register(adapter) else { continue }
            registered.insert(adapter.name)
        }
        registrations[configuration.id]?.toolNames = registered
    }

    /// Drops one session's claim on every server. The tools stay registered while another session
    /// still holds one, so a call already in flight on that session is untouched.
    internal func detach(sessionId: UUID) async {
        for serverId in Array(registrations.keys) {
            guard var registration = registrations[serverId],
                  registration.authorizingSessions.contains(sessionId)
            else { continue }
            registration.authorizingSessions.remove(sessionId)
            if registration.authorizingSessions.isEmpty {
                await detachAll(serverId: serverId)
            } else {
                registrations[serverId] = registration
            }
        }
    }

    private func detachAll(serverId: UUID) async {
        guard let registration = registrations.removeValue(forKey: serverId) else { return }
        for name in registration.toolNames {
            registry.unregister(name: name)
        }
        await registration.client.close()
    }

    /// The server a namespaced tool belongs to, for the approval card and the audit entry. Nil for a
    /// built-in.
    internal func server(owningTool toolName: String) -> MCPServerConfiguration? {
        store.server(owningTool: toolName)
    }

    /// Connects a server once to see whether it answers and what it offers, without registering
    /// anything and without storing anything. The settings pane's Test.
    ///
    /// The token is passed in rather than read back out of the Keychain, so testing a server does
    /// not first have to create it. It used to: Test wrote the configuration and its credential and
    /// then probed what it had written, so a reader checking an endpoint they had typed wrong ended
    /// up with a server in their list they never asked to add.
    internal func probe(
        _ configuration: MCPServerConfiguration,
        token: String
    ) async -> Result<[MCPRemoteTool], MCPClientError> {
        guard !token.isEmpty else { return .failure(.notConfigured) }
        let client = MCPClientSession(
            configuration: configuration,
            transport: MCPRemoteServerTransport(
                endpoint: configuration.endpoint,
                bearerToken: token,
                timeout: MCPClientSession.defaultTimeout
            )
        )
        defer { Task { await client.close() } }
        do {
            return .success(try await client.listTools())
        } catch let error as MCPClientError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
