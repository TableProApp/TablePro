//
//  ConnectionTunnelKind.swift
//  TablePro
//

import Foundation

enum ConnectionTunnelKind: String, CaseIterable, Sendable {
    case ssh
    case cloudflare
    case cloudSQLProxy
    case socksProxy

    /// A database file fetched from an SSH server over SFTP rather than a port forwarded from it.
    ///
    /// It is a tunnel kind because everything that treats the others as one applies here too:
    /// exactly one transport per connection, a manager that owns teardown, and a reconnect path
    /// that rebuilds it. What travels is a file rather than a socket.
    case remoteFile

    /// The transports the connection form offers as switches the user can turn on independently.
    ///
    /// `.remoteFile` is deliberately absent. It is not a switch of its own: it is what an SSH
    /// configuration becomes once it names a file instead of a port, so it can never be on beside
    /// `.ssh` and can never be turned on without it. Anything reasoning about which controls
    /// conflict wants this list; anything reasoning about which transport will run wants
    /// `allCases`.
    static let formToggleable: [ConnectionTunnelKind] = [.ssh, .cloudflare, .cloudSQLProxy, .socksProxy]

    var displayName: String {
        switch self {
        case .ssh: return String(localized: "SSH Tunnel")
        case .cloudflare: return String(localized: "Cloudflare Tunnel")
        case .cloudSQLProxy: return String(localized: "Cloud SQL Auth Proxy")
        case .socksProxy: return String(localized: "SOCKS Proxy")
        case .remoteFile: return String(localized: "Remote Database File")
        }
    }
}

extension DatabaseConnection {
    /// Whether this connection's driver will actually open the file that would be fetched.
    ///
    /// A path on its own is not enough. A libSQL connection left in Remote mode, or a DuckDB
    /// connection set to Quack, ignores the local path entirely, so fetching a file for it downloads
    /// a database nothing opens. Changing a configured remote SQLite connection to MySQL leaves the
    /// path behind in the same way, and without this it would be treated as a remote-file
    /// connection that its own type cannot serve.
    /// Read straight from the metadata registry rather than through `PluginManager`, which is
    /// main-actor isolated. `enabledTunnelKinds` is asked from wherever a connection is being
    /// resolved, so it cannot hop actors; the registry guards its own state with a lock for exactly
    /// this reason.
    var opensRemoteDatabaseFile: Bool {
        guard resolvedSSHConfig.forwardsRemoteFile else { return false }
        guard let capabilities = PluginMetadataRegistry.shared.snapshot(for: type)?.capabilities
        else { return false }
        return capabilities.supportsRemoteDatabaseFile && capabilities.localFilePathField != nil
    }

    var enabledTunnelKinds: [ConnectionTunnelKind] {
        var kinds: [ConnectionTunnelKind] = []
        if opensRemoteDatabaseFile {
            kinds.append(.remoteFile)
        } else if resolvedSSHConfig.enabled {
            kinds.append(.ssh)
        }
        if isCloudflareEnabled { kinds.append(.cloudflare) }
        if isCloudSQLProxyEnabled { kinds.append(.cloudSQLProxy) }
        if isSOCKSProxyEnabled { kinds.append(.socksProxy) }
        return kinds
    }

    var activeTunnelKind: ConnectionTunnelKind? {
        enabledTunnelKinds.count == 1 ? enabledTunnelKinds.first : nil
    }
}
