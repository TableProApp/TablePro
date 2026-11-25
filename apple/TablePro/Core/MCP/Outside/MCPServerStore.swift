import Combine
import Foundation
import TableProMCP

internal enum MCPServerSaveError: Error, Equatable, Sendable {
    case invalid(MCPServerConfigurationError)
    // A new server, or a saved one pointed at another scheme, host or port, must bring its own token.
    case tokenRequired
    case tokenNotSaved
}

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

    // The token is written first, so a Keychain refusal leaves the list and the saved token as they were.
    @discardableResult
    internal func upsert(
        _ configuration: MCPServerConfiguration,
        token: String?
    ) -> MCPServerSaveError? {
        if let error = MCPServerConfigurationValidator.validate(
            name: configuration.name,
            endpoint: configuration.endpoint
        ) {
            return .invalid(error)
        }
        let newToken = token.flatMap { $0.isEmpty ? nil : $0 }
        if newToken == nil {
            guard let saved = server(id: configuration.id),
                  Self.sharesOrigin(saved.endpoint, configuration.endpoint) else { return .tokenRequired }
        }
        if let newToken, !keychain.writeString(newToken, forKey: Self.tokenKey(configuration.id)) {
            return .tokenNotSaved
        }
        var next = servers
        if let index = next.firstIndex(where: { $0.id == configuration.id }) {
            next[index] = configuration
        } else {
            next.append(configuration)
        }
        servers = next
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

    // A saved token may follow a path change, never a move to another scheme, host or port.
    nonisolated internal static func sharesOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(), let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(), let rhsHost = rhs.host?.lowercased() else { return false }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs, scheme: lhsScheme) == effectivePort(rhs, scheme: rhsScheme)
    }

    nonisolated private static func effectivePort(_ url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func tokenKey(_ serverId: UUID) -> String {
        "mcp.outsideServer.\(serverId.uuidString)"
    }

    private func persist() {
        try? defaults.write(servers, to: Self.serversKey)
    }
}
