//
//  MCPServerStore.swift
//  TablePro
//

import Foundation
import os

/// The outside MCP servers this Mac knows about, and their bearer tokens.
///
/// The configuration is device-local JSON in UserDefaults; the token is in the Keychain, keyed by
/// the server's id, so removing a server removes its credential and nothing else has to remember to.
/// Nothing here syncs: a server reachable from this Mac is not necessarily reachable from another,
/// and a token that travelled would be a credential the user did not choose to copy.
@MainActor
@Observable
internal final class MCPServerStore {
    internal static let shared = MCPServerStore()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MCPServerStore")

    private static let defaultsKey = "com.TablePro.mcp.outsideServers"

    internal private(set) var servers: [MCPServerConfiguration] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: any KeychainStoring

    internal init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStoring = KeychainHelper.shared
    ) {
        self.defaults = defaults
        self.keychain = keychain
        servers = Self.decode(defaults.data(forKey: Self.defaultsKey))
    }

    // MARK: - Reads

    internal func server(id: UUID) -> MCPServerConfiguration? {
        servers.first { $0.id == id }
    }

    /// The servers a session on this connection may reach. A nil connection reaches none: a session
    /// with no connection cannot pass the allowlist, and defaulting to "all" there would make a
    /// half-built session the most privileged one in the app.
    internal func servers(allowedFor connectionId: UUID?) -> [MCPServerConfiguration] {
        guard let connectionId else { return [] }
        return servers.filter { $0.allowedConnectionIds.contains(connectionId) }
    }

    /// Whether one tool name, already namespaced, belongs to a server this connection may reach.
    internal func allowsTool(named toolName: String, connectionId: UUID?) -> Bool {
        guard let server = server(owningTool: toolName) else { return false }
        return server.allows(connectionId: connectionId)
    }

    internal func server(owningTool toolName: String) -> MCPServerConfiguration? {
        servers.first { toolName.hasPrefix($0.toolNamespace) }
    }

    // MARK: - Writes

    @discardableResult
    internal func upsert(
        _ configuration: MCPServerConfiguration,
        token: String?
    ) -> MCPServerConfigurationError? {
        if let error = MCPServerConfigurationValidator.validate(
            name: configuration.name,
            endpoint: configuration.endpoint
        ) {
            return error
        }
        if let index = servers.firstIndex(where: { $0.id == configuration.id }) {
            servers[index] = configuration
        } else {
            servers.append(configuration)
        }
        if let token, !token.isEmpty {
            _ = keychain.writeString(token, forKey: Self.tokenKey(configuration.id))
        }
        persist()
        return nil
    }

    /// Removes the server and its credential together. A token left behind would be a live secret
    /// for a server the user believes they deleted.
    internal func remove(id: UUID) {
        servers.removeAll { $0.id == id }
        keychain.delete(forKey: Self.tokenKey(id))
        persist()
    }

    internal func setAllowed(_ isAllowed: Bool, serverId: UUID, connectionId: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        if isAllowed {
            servers[index].allowedConnectionIds.insert(connectionId)
        } else {
            servers[index].allowedConnectionIds.remove(connectionId)
        }
        persist()
    }

    /// Called when a connection is deleted, so its id does not sit in an allowlist forever. A new
    /// connection cannot inherit it (ids are fresh UUIDs), but a stale entry makes the settings pane
    /// lie about how far a server reaches.
    internal func forgetConnection(_ connectionId: UUID) {
        var changed = false
        for index in servers.indices where servers[index].allowedConnectionIds.contains(connectionId) {
            servers[index].allowedConnectionIds.remove(connectionId)
            changed = true
        }
        guard changed else { return }
        persist()
    }

    /// Nil for a locked or cancelled Keychain as well as a missing token. The call that needs it
    /// fails with the server unreachable, which is the honest report: a token TablePro cannot read is
    /// a token it does not have.
    internal func token(for serverId: UUID) -> String? {
        guard case .found(let token) = keychain.readStringResult(forKey: Self.tokenKey(serverId)) else {
            return nil
        }
        return token
    }

    // MARK: - Storage

    private static func tokenKey(_ serverId: UUID) -> String {
        "mcp.outsideServer.\(serverId.uuidString)"
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(servers), forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("Failed to persist outside MCP servers: \(error.localizedDescription)")
        }
    }

    private static func decode(_ data: Data?) -> [MCPServerConfiguration] {
        guard let data else { return [] }
        do {
            return try JSONDecoder().decode([MCPServerConfiguration].self, from: data)
        } catch {
            Self.logger.error("Failed to load outside MCP servers: \(error.localizedDescription)")
            return []
        }
    }
}
