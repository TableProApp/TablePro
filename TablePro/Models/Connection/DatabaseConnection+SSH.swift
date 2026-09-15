//
//  DatabaseConnection+SSH.swift
//  TablePro
//

import Foundation

extension DatabaseConnection {
    static let sshForwardUnixSocketPathKey = "sshForwardUnixSocketPath"

    /// Where the SSH server should connect once the tunnel is up. A socket path takes
    /// precedence over `host`/`port`, which the SSH server never uses in that case.
    var sshForwardDestination: SSHForwardDestination {
        if let path = sshForwardUnixSocketPath {
            return .unixSocket(path: path)
        }
        let endpoint = tunnelForwardEndpoint
        return .tcp(host: endpoint.host, port: endpoint.port)
    }

    func isLinked(toSSHProfile profileId: UUID) -> Bool {
        guard case .profile(let linkedId, _) = sshTunnelMode else { return false }
        return linkedId == profileId
    }

    /// The resolved SSH configuration, derived from `sshTunnelMode`.
    var resolvedSSHConfig: SSHConfiguration {
        switch sshTunnelMode {
        case .disabled:
            return SSHConfiguration()
        case .inline(let config):
            return config
        case .profile(_, let snapshot):
            return snapshot
        }
    }

    /// Resolves the effective SSH configuration for this connection.
    @available(*, deprecated, message: "Use resolvedSSHConfig")
    func effectiveSSHConfig(profile: SSHProfile?) -> SSHConfiguration {
        if sshProfileId != nil, let profile {
            return profile.toSSHConfiguration()
        }
        return sshConfig
    }
}

extension SSHProfile {
    /// This profile's current configuration written into a connection that links to it.
    ///
    /// `.profile(id:snapshot:)` stores a whole `SSHConfiguration` on the connection, and
    /// `resolvedSSHConfig` hands that snapshot to the tunnel, the URL formatter and every display
    /// string. Only the secrets were ever read back from the profile, so a profile edit reached a
    /// linked connection's password and nothing else. This is the write the edit owes them.
    ///
    /// `remoteFilePath` and `remoteFileAccess` belong to the connection, not to the profile, so
    /// they survive untouched.
    func applied(to connection: DatabaseConnection) -> DatabaseConnection {
        guard case .profile(let linkedId, let snapshot) = connection.sshTunnelMode,
              linkedId == id
        else { return connection }

        var refreshed = toSSHConfiguration()
        refreshed.remoteFilePath = snapshot.remoteFilePath
        refreshed.remoteFileAccess = snapshot.remoteFileAccess
        guard refreshed != snapshot else { return connection }

        var updated = connection
        updated.sshTunnelMode = .profile(id: linkedId, snapshot: refreshed)
        updated.sshConfig = refreshed
        return updated
    }
}
