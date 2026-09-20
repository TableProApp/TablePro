import CLibSSH2
import Foundation
import TableProDatabase
import TableProModels
import TableProSSHTransport

nonisolated enum SSHTunnelFactory {
    private static let initialized: Bool = {
        libssh2_init(0)
        return true
    }()

    /// Builds an authenticated, forwarding tunnel, or releases everything it built.
    ///
    /// The `defer` guards the whole function body rather than a `do`/`catch` region, so a step
    /// appended later cannot escape it: eight throwing steps ran unguarded before, and five failed
    /// handshakes leaked ten descriptors, each an established TCP socket to the SSH server. The
    /// flag is the repo's own hand-over idiom, the `adopted`/`defer` pair both PostgreSQL connect
    /// paths use.
    ///
    /// `Stages` is a protocol so the guarantee is testable with no SSH server in reach: a spy that
    /// throws at any step asserts exactly one `discard()`.
    static func create<Stages: SSHTunnelStages>(
        config: SSHConfiguration,
        remoteHost: String,
        remotePort: Int,
        credentials: SSHTunnelCredentials,
        prompter: (any ConnectionPrompter)?,
        hostKeyStore: HostKeyStore = .shared,
        makeStages: @Sendable () -> Stages = { LibSSH2TunnelStages() }
    ) async throws -> Stages.Tunnel {
        _ = initialized

        guard config.jumpHosts.isEmpty else { throw SSHTunnelError.jumpHostsUnsupported }

        try await LocalNetworkPermission.shared.ensureAccess(for: config.host)

        let stages = makeStages()
        var handedOver = false
        defer { if !handedOver { stages.discard() } }

        try await stages.connect(host: config.host, port: config.resolvedPort)
        try await stages.handshake()

        let presentedKey = try await stages.hostKey()
        try await HostKeyVerifier.verify(
            keyData: presentedKey.keyData,
            keyType: presentedKey.keyType,
            hostname: config.host,
            port: config.resolvedPort,
            store: hostKeyStore,
            prompter: prompter
        )

        try await authenticate(stages, config: config, credentials: credentials)

        let tunnel = try await stages.beginForwarding(
            destination: .tcp(host: remoteHost, port: remotePort)
        )
        handedOver = true
        return tunnel
    }

    private static func authenticate<Stages: SSHTunnelStages>(
        _ stages: Stages,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) async throws {
        switch config.authMethod {
        case .password:
            guard let password = credentials.password else {
                throw SSHTunnelError.authenticationFailed("No SSH password provided")
            }
            try await stages.authenticatePassword(username: config.username, password: password)

        case .privateKey:
            switch credentials.privateKeySource(keyPath: config.privateKeyPath) {
            case .inMemory(let keyContent):
                try await stages.authenticatePublicKeyFromMemory(
                    username: config.username,
                    keyContent: keyContent,
                    passphrase: credentials.keyPassphrase
                )
            case .file(let keyPath):
                try await stages.authenticatePublicKey(
                    username: config.username,
                    keyPath: keyPath,
                    passphrase: credentials.keyPassphrase
                )
            case .missing:
                throw SSHTunnelError.authenticationFailed("No private key provided")
            }

        case .none:
            try await stages.authenticateNone(username: config.username)

        default:
            throw SSHTunnelError.authenticationFailed(
                "Auth method \(config.authMethod.rawValue) not supported on iOS"
            )
        }
    }
}
