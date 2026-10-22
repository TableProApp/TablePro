import TableProModels

nonisolated extension SSHConfiguration.SSHAuthMethod {
    // iOS has no agent, so an agent tunnel signs in with a key on this device; the synced value stays the Mac's.
    var onDevice: SSHConfiguration.SSHAuthMethod {
        switch self {
        case .sshAgent: .privateKey
        case .password, .privateKey, .keyboardInteractive, .none: self
        }
    }
}
