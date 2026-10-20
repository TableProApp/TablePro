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

    private struct HopKey {
        let source: SSHTunnelCredentials.PrivateKeySource
        let passphrase: String?
    }

    private enum Role {
        case jumpHost(HopKey)
        case sshServer
    }

    private struct Target {
        let host: String
        let port: Int
        let username: String
        let role: Role
    }

    // The `defer` guards the whole body, so a step added later cannot leak what was built: unguarded
    // steps once left two descriptors open per failed handshake. `Stages` lets a spy test that.
    static func create<Stages: SSHTunnelStages>(
        config: SSHConfiguration,
        remoteHost: String,
        remotePort: Int,
        credentials: SSHTunnelCredentials,
        jumpHostCredentials: [UUID: JumpHostCredential] = [:],
        prompter: (any ConnectionPrompter)?,
        hostKeyStore: HostKeyStore = .shared,
        ensureLocalNetworkAccess: @Sendable (String) async throws -> Void = { host in
            try await LocalNetworkPermission.shared.ensureAccess(for: host)
        },
        makeStages: @Sendable () -> Stages = { LibSSH2TunnelStages() }
    ) async throws -> Stages.Tunnel {
        _ = initialized

        try requireValidPort(remotePort, of: remoteHost)
        let targets = try dialOrder(config: config, credentials: credentials, jumpHostCredentials: jumpHostCredentials)

        // Only the first host is dialed from the device; every later one is opened by the hop before it.
        try await ensureLocalNetworkAccess(targets[0].host)

        let stages = makeStages()
        var handedOver = false
        defer { if !handedOver { stages.discard() } }

        for (index, target) in targets.enumerated() {
            if index == 0 {
                try await failing(as: target) {
                    try await stages.connect(host: target.host, port: target.port)
                }
            } else {
                try await failing(as: targets[index - 1]) {
                    try await stages.jump(toHost: target.host, port: target.port)
                }
            }
            try await failing(as: target) {
                try await signIn(
                    to: target,
                    stages: stages,
                    config: config,
                    credentials: credentials,
                    prompter: prompter,
                    hostKeyStore: hostKeyStore
                )
            }
        }

        let tunnel = try await stages.beginForwarding(
            destination: .tcp(host: remoteHost, port: remotePort)
        )
        handedOver = true
        return tunnel
    }

    // Every check that needs no network runs before anything is dialed, so a hop without a key on
    // this device is named at once instead of after the hops before it have signed in.
    private static func dialOrder(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        jumpHostCredentials: [UUID: JumpHostCredential]
    ) throws -> [Target] {
        var targets: [Target] = []
        for hop in config.jumpHosts {
            guard hasUsername(hop.username) else { throw SSHTunnelError.usernameMissing(host: hop.host) }
            try requireValidPort(hop.resolvedPort, of: hop.host)
            let key = try hopKey(for: hop, credential: jumpHostCredentials[hop.id], config: config, credentials: credentials)
            targets.append(Target(host: hop.host, port: hop.resolvedPort, username: hop.username, role: .jumpHost(key)))
        }
        guard hasUsername(config.username) else { throw SSHTunnelError.usernameMissing(host: config.host) }
        try requireValidPort(config.resolvedPort, of: config.host)
        targets.append(Target(host: config.host, port: config.resolvedPort, username: config.username, role: .sshServer))
        return targets
    }

    // A channel takes the port as an Int32, so a larger value would trap instead of failing.
    private static func requireValidPort(_ port: Int, of host: String) throws {
        guard (1...65_535).contains(port) else {
            throw SSHTunnelError.connectionFailed(
                "Port \(port) of \(host) is out of range. Use a value between 1 and 65535."
            )
        }
    }

    private static func hopKey(
        for hop: SSHJumpHost,
        credential: JumpHostCredential?,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) throws -> HopKey {
        switch credential {
        case .some(.privateKey(let key, let passphrase)) where !key.isEmpty:
            return HopKey(source: .inMemory(key), passphrase: passphrase.flatMap { $0.isEmpty ? nil : $0 })
        case .some(.sshServerKey):
            guard let source = serverKeyOnDevice(config: config, credentials: credentials) else {
                throw SSHTunnelError.jumpHostSharedKeyMissing(host: hop.host)
            }
            return HopKey(source: source, passphrase: credentials.keyPassphrase)
        case .some(.privateKey), .none:
            throw SSHTunnelError.jumpHostNeedsKey(host: hop.host)
        }
    }

    // A synced Mac path reaches here untouched, and it names a file only the Mac has.
    private static func serverKeyOnDevice(
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials
    ) -> SSHTunnelCredentials.PrivateKeySource? {
        guard config.authMethod.onDevice == .privateKey else { return nil }
        let source = credentials.privateKeySource(keyPath: config.privateKeyPath)
        switch source {
        case .inMemory:
            return source
        case .file(let path):
            return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) ? source : nil
        case .missing:
            return nil
        }
    }

    private static func hasUsername(_ username: String) -> Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func signIn<Stages: SSHTunnelStages>(
        to target: Target,
        stages: Stages,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        prompter: (any ConnectionPrompter)?,
        hostKeyStore: HostKeyStore
    ) async throws {
        try await stages.handshake()

        let presentedKey = try await stages.hostKey()
        try await HostKeyVerifier.verify(
            keyData: presentedKey.keyData,
            keyType: presentedKey.keyType,
            hostname: target.host,
            port: target.port,
            store: hostKeyStore,
            prompter: prompter
        )

        switch target.role {
        case .jumpHost(let key):
            try await authenticate(
                stages,
                username: target.username,
                key: key.source,
                passphrase: key.passphrase,
                then: nil
            )
        case .sshServer:
            try await authenticate(stages, config: config, credentials: credentials, prompter: prompter)
        }
    }

    // A hop's failure names the hop. A host key question already names its host and port, and
    // anything that is not an SSH error, such as a cancellation, passes through as it is.
    private static func failing(as target: Target, _ step: () async throws -> Void) async throws {
        guard case .jumpHost = target.role else {
            try await step()
            return
        }
        do {
            try await step()
        } catch let error as SSHTunnelError {
            switch error {
            case .connectionFailed, .handshakeFailed, .authenticationFailed, .noAvailablePort,
                 .channelOpenFailed, .tunnelClosed, .negotiationFailed,
                 .securityKeyUnsupported, .passphraseRequired, .passphraseIncorrect,
                 .additionalFactorRequired, .promptUnanswerable, .verificationCodeRejected:
                throw SSHTunnelError.jumpHostFailed(host: target.host, reason: error.localizedDescription)
            case .hostKeyRejected, .hostKeyUnverified, .usernameMissing, .jumpHostNeedsKey,
                 .jumpHostSharedKeyMissing, .jumpHostFailed, .jumpHostKeysUnreadable:
                throw error
            }
        }
    }

    // Every method but None is followed by keyboard-interactive, as on the Mac: a second factor, or a
    // PAM server that takes the password that way.
    private static func authenticate<Stages: SSHTunnelStages>(
        _ stages: Stages,
        config: SSHConfiguration,
        credentials: SSHTunnelCredentials,
        prompter: (any ConnectionPrompter)?
    ) async throws {
        func secondStep(password: String?) -> KeyboardInteractiveCredentials {
            KeyboardInteractiveCredentials(
                password: password,
                config: config,
                totpSecret: credentials.totpSecret,
                prompter: prompter
            )
        }

        switch config.authMethod.onDevice {
        case .password:
            guard let password = credentials.password else {
                throw SSHTunnelError.authenticationFailed("No SSH password provided")
            }
            try await stages.authenticatePassword(
                username: config.username,
                password: password,
                then: secondStep(password: password)
            )

        case .privateKey, .sshAgent:
            try await authenticate(
                stages,
                username: config.username,
                key: credentials.privateKeySource(keyPath: config.privateKeyPath),
                passphrase: credentials.keyPassphrase,
                then: secondStep(password: nil)
            )

        case .keyboardInteractive:
            try await stages.authenticateKeyboardInteractive(
                username: config.username,
                with: secondStep(password: credentials.password)
            )

        case .none:
            try await stages.authenticateNone(username: config.username)
        }
    }

    private static func authenticate<Stages: SSHTunnelStages>(
        _ stages: Stages,
        username: String,
        key: SSHTunnelCredentials.PrivateKeySource,
        passphrase: String?,
        then secondStep: KeyboardInteractiveCredentials?
    ) async throws {
        switch key {
        case .inMemory(let keyContent):
            try await stages.authenticatePublicKeyFromMemory(
                username: username,
                keyContent: keyContent,
                passphrase: passphrase,
                then: secondStep
            )
        case .file(let keyPath):
            try await stages.authenticatePublicKey(
                username: username,
                keyPath: keyPath,
                passphrase: passphrase,
                then: secondStep
            )
        case .missing:
            throw SSHTunnelError.authenticationFailed("No private key provided")
        }
    }
}
