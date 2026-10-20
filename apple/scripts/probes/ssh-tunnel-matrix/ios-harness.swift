import Foundation
import TableProDatabase
import TableProModels
import TableProSSHTransport

// Compiled into one module with the iOS app's tunnel sources (build-ios-harness.sh) to reach the
// internal SSHTunnelFactory. The modes live in harness-common.swift.

@MainActor
struct AcceptEveryHostKey: ConnectionPrompter {
    func confirm(_ question: ConnectionQuestion) async -> Bool { true }
}

nonisolated extension SSHTunnel: HarnessTunnel {}

nonisolated enum TunnelOpener {
    static func open(_ options: HarnessOptions, prompter: any ConnectionPrompter) async throws -> SSHTunnel {
        let (config, credentials) = try request(options)
        let destination = try HarnessOptions.endpoint(options.target)
        let store = HostKeyStore(
            filePath: (options.knownHostsDirectory as NSString).appendingPathComponent("known_hosts_\(UUID().uuidString)")
        )
        return try await SSHTunnelFactory.create(
            config: config,
            remoteHost: destination.host,
            remotePort: destination.port,
            credentials: credentials,
            jumpHostCredentials: try hopCredentials(options, hops: config.jumpHosts),
            prompter: prompter,
            hostKeyStore: store
        )
    }

    // "server" is Same Key as SSH Server; any other value is a key file, read in as the app keeps a hop key.
    private static func hopCredentials(_ options: HarnessOptions, hops: [SSHJumpHost]) throws -> [UUID: JumpHostCredential] {
        guard let jumpKey = options.jumpKey else { return [:] }
        let credential: JumpHostCredential = jumpKey == "server"
            ? .sshServerKey
            : .privateKey(key: try String(contentsOfFile: jumpKey, encoding: .utf8), passphrase: options.jumpPassphrase)
        return Dictionary(uniqueKeysWithValues: hops.map { ($0.id, credential) })
    }

    private static func request(_ options: HarnessOptions) throws -> (SSHConfiguration, SSHTunnelCredentials) {
        var config = SSHConfiguration(host: options.host, port: options.port, username: options.user)
        config.jumpHosts = try options.jumps.map { hop in
            let endpoint = try HarnessOptions.endpoint(hop)
            return SSHJumpHost(host: endpoint.host, port: endpoint.port, username: options.user)
        }
        if options.totpSecret != nil {
            config.totpMode = TOTPMode.autoGenerate.rawValue
        }
        switch options.auth {
        case "password":
            config.authMethod = .password
        case "key", "agent":
            config.authMethod = options.auth == "agent" ? .sshAgent : .privateKey
            if let path = options.keyMemory {
                let key = try String(contentsOfFile: path, encoding: .utf8)
                let credentials = SSHTunnelCredentials(
                    keyPassphrase: options.passphrase,
                    privateKey: key,
                    totpSecret: options.totpSecret
                )
                return (config, credentials)
            }
            config.privateKeyPath = options.keyFile
            return (config, SSHTunnelCredentials(keyPassphrase: options.passphrase, totpSecret: options.totpSecret))
        case "kbdint":
            config.authMethod = .keyboardInteractive
        case "none":
            config.authMethod = .none
        default:
            throw HarnessFailure(description: "unknown --auth \(options.auth)")
        }
        return (config, SSHTunnelCredentials(password: options.password, totpSecret: options.totpSecret))
    }
}

@main
enum IOSTunnelHarness {
    static func main() async {
        let prompter = AcceptEveryHostKey()
        await TunnelHarness.run { options in
            try await TunnelOpener.open(options, prompter: prompter)
        }
    }
}
