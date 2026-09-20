import CLibSSH2
import Foundation
import TableProDatabase
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
        credentials: SSHTunnelCredentials,
        prompter: (any ConnectionPrompter)?
    ) async throws -> SSHTunnel {
        _ = initialized

        try await LocalNetworkPermission.shared.ensureAccess(for: config.host)

        let tunnel = SSHTunnel()

        try await tunnel.connect(host: config.host, port: config.resolvedPort)
        try await tunnel.handshake()

        let presentedKey = try await tunnel.hostKey()
        do {
            try await HostKeyVerifier.verify(
                keyData: presentedKey.keyData,
                keyType: presentedKey.keyType,
                hostname: config.host,
                port: config.resolvedPort,
                prompter: prompter
            )
        } catch {
            await tunnel.close()
            throw error
        }

        switch config.authMethod {
        case .password:
            guard let password = credentials.password else {
                throw SSHTunnelError.authenticationFailed("No SSH password provided")
            }
            try await tunnel.authenticatePassword(username: config.username, password: password)

        case .privateKey:
            switch credentials.privateKeySource(keyPath: config.privateKeyPath) {
            case .inMemory(let keyContent):
                try await tunnel.authenticatePublicKeyFromMemory(
                    username: config.username,
                    keyContent: keyContent,
                    passphrase: credentials.keyPassphrase
                )
            case .file(let keyPath):
                try await tunnel.authenticatePublicKey(
                    username: config.username,
                    keyPath: keyPath,
                    passphrase: credentials.keyPassphrase
                )
            case .missing:
                throw SSHTunnelError.authenticationFailed("No private key provided")
            }

        case .none:
            try await tunnel.authenticateNone(username: config.username)

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
