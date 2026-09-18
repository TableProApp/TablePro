//
//  MCPServerStore.swift
//  TablePro
//

import Combine
import Foundation
import os

/// The outside MCP servers this Mac knows about, and their bearer tokens.
///
/// The configuration is device-local JSON in UserDefaults; the token is in the Keychain, keyed by
/// the server's id, so removing a server removes its credential and nothing else has to remember to.
/// Nothing here syncs: a server reachable from this Mac is not necessarily reachable from another,
/// and a token that travelled would be a credential the user did not choose to copy.
@MainActor
internal final class MCPServerStore: ObservableObject {
    internal static let shared = MCPServerStore()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MCPServerStore")

    private static let defaultsKey = "com.TablePro.mcp.outsideServers"

    @Published internal private(set) var servers: [MCPServerConfiguration] = []

    private let defaults: UserDefaults
    private let keychain: any KeychainStoring

    /// Both come from `AppStorageEnvironment` rather than from `.standard` and the real Keychain.
    /// A store that names those directly reads the developer's own data under test isolation, which
    /// is the one thing the sandbox exists to prevent.
    /// The defaults come from `AppStorageEnvironment` rather than from `.standard`, so a store that
    /// names them directly cannot read the developer's own data under test isolation.
    ///
    /// The Keychain is `MCPServerTokenKeychain` in production and the sandbox's own file store under
    /// test. `AppStorageEnvironment.keychain` is `KeychainHelper`, which marks every item
    /// synchronizable once the user turns on connection password sync, and a token for a server
    /// this Mac can reach is not a credential they chose to copy to another one.
    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        keychain: (any KeychainStoring)? = nil
    ) {
        self.defaults = defaults
        let environment = AppStorageEnvironment.shared
        self.keychain = keychain ?? (environment.isIsolated ? environment.keychain : MCPServerTokenKeychain())
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
        var next = servers
        if isAllowed {
            next[index].allowedConnectionIds.insert(connectionId)
        } else {
            next[index].allowedConnectionIds.remove(connectionId)
        }
        servers = next
        persist()
    }

    /// Called when a connection is deleted, so its id does not sit in an allowlist forever. A new
    /// connection cannot inherit it (ids are fresh UUIDs), but a stale entry makes the settings pane
    /// lie about how far a server reaches.
    internal func forgetConnection(_ connectionId: UUID) {
        var next = servers
        var changed = false
        for index in next.indices where next[index].allowedConnectionIds.contains(connectionId) {
            next[index].allowedConnectionIds.remove(connectionId)
            changed = true
        }
        guard changed else { return }
        servers = next
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
