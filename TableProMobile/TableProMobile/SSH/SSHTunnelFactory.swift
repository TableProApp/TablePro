import CLibSSH2
import Foundation
import TableProModels

enum SSHTunnelFactory {
    private static let initialized: Bool = {
        libssh2_init(0)
        return true
    }()

    static func create(
        config: SSHConfiguration,
        remoteHost: String,
        remotePort: Int,
        sshPassword: String?,
        keyPassphrase: String?
    ) async throws -> SSHTunnel {
        _ = initialized

        try await LocalNetworkPermission.shared.ensureAccess(for: config.host)

        let tunnel = SSHTunnel()

        try await tunnel.connect(host: config.host, port: config.port)
        try await tunnel.handshake()

        switch config.authMethod {
        case .password:
            guard let password = sshPassword else {
                throw SSHTunnelError.authenticationFailed("No SSH password provided")
            }
            try await tunnel.authenticatePassword(username: config.username, password: password)

        case .privateKey:
            if let keyContent = config.privateKeyData, !keyContent.isEmpty {
                try await tunnel.authenticatePublicKeyFromMemory(
                    username: config.username,
                    keyContent: keyContent,
                    passphrase: keyPassphrase
                )
            } else if let keyPath = config.privateKeyPath, !keyPath.isEmpty {
                try await tunnel.authenticatePublicKey(
                    username: config.username,
                    keyPath: keyPath,
                    passphrase: keyPassphrase
                )
            } else {
                throw SSHTunnelError.authenticationFailed("No private key provided")
            }

        default:
            throw SSHTunnelError.authenticationFailed(
                "Auth method \(config.authMethod.rawValue) not supported on iOS"
            )
        }

        try await tunnel.startForwarding(remoteHost: remoteHost, remotePort: remotePort)
        await tunnel.startKeepAlive()

        return tunnel
    }
}
