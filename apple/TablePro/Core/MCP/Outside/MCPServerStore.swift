//
//  MCPServerStore.swift
//  TablePro
//

import Combine
import Foundation
import TableProMCP

// Device-local and never synced: a server this Mac reaches may not be reachable from another.
@MainActor
internal final class MCPServerStore: ObservableObject {
    internal static let shared = MCPServerStore()

    private static let serversKey = JSONDefaultsKey<[MCPServerConfiguration]>("com.TablePro.mcp.outsideServers")

    @Published internal private(set) var servers: [MCPServerConfiguration] = []

    private let defaults: UserDefaults
    private let keychain: any KeychainStoring

    // Not `AppStorageEnvironment.keychain` in production: it syncs items once password sync is on.
    internal init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        keychain: (any KeychainStoring)? = nil
    ) {
        self.defaults = defaults
        let environment = AppStorageEnvironment.shared
        self.keychain = keychain ?? (environment.isIsolated ? environment.keychain : MCPServerTokenKeychain())
        servers = defaults.read(Self.serversKey).value ?? []
    }

    // MARK: - Reads

    internal func server(id: UUID) -> MCPServerConfiguration? {
        servers.first { $0.id == id }
    }

    // A nil connection reaches none, so a half-built session is never the most privileged one.
    internal func servers(allowedFor connectionId: UUID?) -> [MCPServerConfiguration] {
        guard let connectionId else { return [] }
        return servers.filter { $0.allowedConnectionIds.contains(connectionId) }
    }

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

    // A stale id would make the settings pane overstate how far a server reaches.
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

    // Nil for a locked or cancelled Keychain too: the call then fails with the server unreachable.
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
        try? defaults.write(servers, to: Self.serversKey)
    }
}
