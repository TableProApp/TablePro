//
//  DatabaseConnection+SSH.swift
//  TablePro
//

extension DatabaseConnection {
    static let sshForwardUnixSocketPathKey = "sshForwardUnixSocketPath"

    /// Where the SSH server should connect once the tunnel is up. A socket path takes
    /// precedence over `host`/`port`, which the SSH server never uses in that case.
    var sshForwardDestination: SSHForwardDestination {
        if let path = sshForwardUnixSocketPath {
            return .unixSocket(path: path)
        }
        return .tcp(host: host, port: port)
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
