import Foundation
import TableProSSHConfig
import TableProSSHTransport

// Compiled into one module with the macOS app's tunnel sources (build-mac-harness.sh) to reach the
// internal LibSSH2TunnelFactory. The app files it leaves out open UI, so the stand-ins below take
// their place: every host key is trusted, a passphrase prompt is dismissed, and a
// keyboard-interactive prompt gets --kbdint-answer or an empty answer. The modes live in
// harness-common.swift.

nonisolated enum MacHarness {
    static let options = TunnelHarness.options()
}

nonisolated struct AppStorageEnvironment: Sendable {
    static let shared = AppStorageEnvironment(
        applicationSupportRoot: URL(fileURLWithPath: MacHarness.options.knownHostsDirectory, isDirectory: true),
        isIsolated: true
    )

    let applicationSupportRoot: URL
    let isIsolated: Bool
}

nonisolated enum HostKeyVerifier {
    static func verify(
        keyData: Data,
        keyType: String,
        hostname: String,
        port: Int,
        attempt: SSHConnectionAttempt? = nil
    ) async throws {
        try attempt?.check(for: .tunnel("\(hostname):\(port)"))
    }
}

nonisolated struct PassphrasePromptResult: Sendable {
    let passphrase: String
    let saveToKeychain: Bool
}

nonisolated final class PromptPassphraseProvider: Sendable {
    init(keyPath: String, attempt: SSHConnectionAttempt? = nil, timeoutEndpoint: ConnectionTimeoutEndpoint? = nil) {}

    func providePassphrase() throws -> PassphrasePromptResult? { nil }
}

nonisolated final class PromptKeyboardInteractiveProvider: KeyboardInteractivePromptProvider {
    init(attempt: SSHConnectionAttempt? = nil, timeoutEndpoint: ConnectionTimeoutEndpoint? = nil) {}

    func provideResponses(for challenge: KeyboardInteractiveChallenge, attempt: Int) throws -> [String] {
        challenge.prompts.map { _ in MacHarness.options.kbdintAnswer ?? "" }
    }
}

nonisolated extension LibSSH2Tunnel: HarnessTunnel {}

nonisolated enum MacTunnelOpener {
    private static let portAttempts = 5

    // What SSHTunnelManager.createTunnel does, with a free port in place of its random one.
    static func open(_ options: HarnessOptions) async throws -> LibSSH2Tunnel {
        let config = try configuration(options)
        let target = try HarnessOptions.endpoint(options.target)
        let destination = SSHForwardDestination.tcp(host: target.host, port: target.port)
        let credentials = SSHTunnelCredentials(
            sshPassword: options.password,
            keyPassphrase: options.passphrase,
            totpSecret: options.totpSecret,
            keyboardInteractivePromptProvider: nil
        )
        let deadline = ConnectionDeadline(configuredSeconds: nil)
        var attempt = 1
        while true {
            let localPort = try LocalClient.freePort()
            do {
                let tunnel = try await Task.detached {
                    try await LibSSH2TunnelFactory.createTunnel(
                        connectionId: UUID(),
                        config: config,
                        credentials: credentials,
                        destination: destination,
                        localPort: localPort,
                        deadline: deadline
                    )
                }.value
                tunnel.startForwarding(destination: destination)
                tunnel.startKeepAlive()
                return tunnel
            } catch SSHTunnelError.tunnelCreationFailed(let message)
                where message.contains("already in use") && attempt < portAttempts {
                attempt += 1
            }
        }
    }

    private static func configuration(_ options: HarnessOptions) throws -> SSHConfiguration {
        guard options.keyMemory == nil else { throw HarnessFailure(description: "the Mac reads a key from a file only") }
        var config = SSHConfiguration(enabled: true, host: options.host, port: options.port, username: options.user)
        config.jumpHosts = try options.jumps.map { hop in
            let endpoint = try HarnessOptions.endpoint(hop)
            var jumpHost = SSHJumpHost(host: endpoint.host, port: endpoint.port, username: options.user)
            try applyHopKey(options, to: &jumpHost)
            return jumpHost
        }
        switch options.auth {
        case "password":
            config.authMethod = .password
        case "key":
            guard let keyFile = options.keyFile else { throw HarnessFailure(description: "--auth key needs --key-file") }
            config.authMethod = .privateKey
            config.privateKeyPath = keyFile
        case "agent":
            // A key file here is the connection's Identity File, which the agent's keys are matched against.
            config.authMethod = .sshAgent
            config.agentSocketPath = options.agentSocket ?? ""
            config.privateKeyPath = options.keyFile ?? ""
        case "kbdint":
            config.authMethod = .keyboardInteractive
        case "none":
            config.authMethod = .none
        default:
            throw HarnessFailure(description: "unknown --auth \(options.auth)")
        }
        if options.totpSecret != nil {
            config.totpMode = .autoGenerate
        }
        return config
    }

    // "agent" signs in to the hop with the agent; any other value is the hop's key file.
    private static func applyHopKey(_ options: HarnessOptions, to jumpHost: inout SSHJumpHost) throws {
        guard options.jumpPassphrase == nil else {
            throw HarnessFailure(description: "a Mac jump host has no passphrase of its own")
        }
        switch options.jumpKey {
        case nil, "agent":
            jumpHost.authMethod = .sshAgent
        case "server":
            throw HarnessFailure(description: "a Mac jump host has no Same Key as SSH Server")
        case let path?:
            jumpHost.authMethod = .privateKey
            jumpHost.privateKeyPath = path
        }
    }
}

@main
enum MacTunnelHarness {
    static func main() async {
        await TunnelHarness.run { options in
            try await MacTunnelOpener.open(options)
        }
    }
}
