//
//  DatabaseConnection+SSH.swift
//  TablePro
//

extension DatabaseConnection {
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
