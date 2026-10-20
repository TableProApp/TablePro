//
//  SSHTunnelFactoryTests.swift
//  TableProMobileTests
//
//  The factory's hand-over guarantee. Every step between building the session and returning the
//  tunnel can throw, and each one that escaped left an established TCP socket to the SSH server
//  behind: measured, five failed handshakes leaked ten descriptors. The `defer` guards the whole
//  function body, so a step added later is covered by construction.
//

import Foundation
import os
import TableProDatabase
import TableProModels
import TableProSSHTransport
import Testing

@testable import TableProMobile

@Suite("SSHTunnelFactory hand-over")
struct SSHTunnelFactoryTests {
    @Test("Every step that throws releases what the factory had built", arguments: SpyTunnelStages.Step.allCases)
    func throwingStepDiscardsOnce(step: SpyTunnelStages.Step) async {
        let stages = SpyTunnelStages(failingAt: step)
        let hops = step == .jump ? [Self.bastion] : []

        await #expect(throws: SpyFailure.self) {
            try await Self.create(
                stages: stages,
                authMethod: step.authMethod,
                jumpHosts: hops,
                jumpHostCredentials: [Self.bastion.id: .privateKey(key: "HOP KEY", passphrase: nil)]
            )
        }

        #expect(stages.discardCount == 1)
    }

    @Test("A tunnel that reaches the caller is never discarded")
    func successHandsOver() async throws {
        let stages = SpyTunnelStages()

        let tunnel = try await Self.create(stages: stages, authMethod: .password)

        #expect(tunnel === stages.tunnel)
        #expect(stages.discardCount == 0)
        #expect(stages.forwardedTo == .tcp(host: "db.internal", port: 5_432))
    }

    @Test("A password method with no password releases the session it already built")
    func missingPasswordDiscards() async {
        let stages = SpyTunnelStages()

        await #expect(throws: SSHTunnelError.self) {
            try await Self.create(stages: stages, authMethod: .password, credentials: SSHTunnelCredentials())
        }

        #expect(stages.discardCount == 1)
    }

    @Test("A private key method with neither a key nor a path releases the session it already built")
    func missingPrivateKeyDiscards() async {
        let stages = SpyTunnelStages()

        await #expect(throws: SSHTunnelError.self) {
            try await Self.create(
                stages: stages,
                authMethod: .privateKey,
                credentials: SSHTunnelCredentials(),
                privateKeyPath: nil
            )
        }

        #expect(stages.discardCount == 1)
    }

    @Test("An auth method iOS cannot perform releases the session it already built")
    func unsupportedAuthMethodDiscards() async {
        let stages = SpyTunnelStages()

        await #expect(throws: SSHTunnelError.self) {
            try await Self.create(stages: stages, authMethod: .keyboardInteractive)
        }

        #expect(stages.discardCount == 1)
    }

    @Test("An unanswerable host key question releases the session it already built")
    func rejectedHostKeyDiscards() async {
        let stages = SpyTunnelStages()

        await #expect(throws: SSHTunnelError.self) {
            try await Self.create(stages: stages, authMethod: .password, prompter: nil)
        }

        #expect(stages.discardCount == 1)
    }

    @Test("A host key the user refuses releases the session it already built")
    func refusedHostKeyDiscards() async {
        let stages = SpyTunnelStages()

        await #expect(throws: SSHTunnelError.self) {
            try await Self.create(stages: stages, authMethod: .password, prompter: StubPrompter(answer: false))
        }

        #expect(stages.discardCount == 1)
    }

    @Test("Cancelling while a step is suspended still releases what was built")
    func cancellationDiscards() async {
        let stages = SpyTunnelStages(suspendingAt: .handshake)

        let task = Task {
            try await Self.create(stages: stages, authMethod: .password)
        }

        await stages.waitUntilSuspended()
        task.cancel()
        let result = await task.result

        if case .success = result {
            Issue.record("expected the cancelled caller to throw")
        }
        #expect(stages.discardCount == 1)
    }

    // MARK: - Jump hosts

    @Test("Each hop is dialed, verified and signed in to in order, then the SSH server, then forwarding")
    func chainDialsInOrder() async throws {
        let stages = SpyTunnelStages()
        let prompter = HostKeyQuestionRecorder()
        let first = SSHJumpHost(host: "bastion1.internal", port: nil, username: "jump1")
        let second = SSHJumpHost(host: "bastion2.internal", port: 2_222, username: "jump2")
        var config = Self.chainConfig(authMethod: .privateKey)
        config.jumpHosts = [first, second]

        let tunnel = try await SSHTunnelFactory.create(
            config: config,
            destination: .tcp(host: "db.internal", port: 5_432),
            credentials: SSHTunnelCredentials(keyPassphrase: "server pass", privateKey: "SERVER KEY"),
            jumpHostCredentials: [
                first.id: .privateKey(key: "HOP ONE KEY", passphrase: "hop pass"),
                second.id: .sshServerKey
            ],
            prompter: prompter,
            hostKeyStore: Self.temporaryHostKeyStore(),
            ensureLocalNetworkAccess: { _ in },
            makeStages: { stages }
        )

        #expect(tunnel === stages.tunnel)
        #expect(stages.discardCount == 0)
        #expect(prompter.questions == ["bastion1.internal:22", "bastion2.internal:2222", "db-ssh.internal:22"])
        #expect(stages.calls == [
            "connect bastion1.internal:22",
            "handshake",
            "hostKey",
            "key jump1 HOP ONE KEY hop pass",
            "jump bastion2.internal:2222",
            "handshake",
            "hostKey",
            "key jump2 SERVER KEY server pass",
            "jump db-ssh.internal:22",
            "handshake",
            "hostKey",
            "key deploy SERVER KEY server pass",
            "forward"
        ])
    }

    @Test("A hop with no key on this device is refused before anything is dialed, naming the hop")
    func hopWithoutKeyIsRefusedBeforeDialing() async {
        let stages = SpyTunnelStages()
        let localNetwork = LocalNetworkRecorder()

        await #expect(throws: SSHTunnelError.jumpHostNeedsKey(host: Self.bastion.host)) {
            try await Self.create(
                stages: stages,
                authMethod: .password,
                jumpHosts: [Self.bastion],
                localNetwork: localNetwork
            )
        }

        #expect(stages.connectCount == 0)
        #expect(stages.discardCount == 0)
        #expect(localNetwork.probed.isEmpty)
    }

    @Test("Same Key over an SSH server that signs in with a password is refused before dialing")
    func sameKeyOverPasswordServerIsRefused() async {
        let stages = SpyTunnelStages()

        await #expect(throws: SSHTunnelError.jumpHostSharedKeyMissing(host: Self.bastion.host)) {
            try await Self.create(
                stages: stages,
                authMethod: .password,
                jumpHosts: [Self.bastion],
                jumpHostCredentials: [Self.bastion.id: .sshServerKey]
            )
        }

        #expect(stages.connectCount == 0)
    }

    @Test(
        "Same Key over an SSH server key that is not on this device is refused before dialing",
        arguments: [String?.some("~/.ssh/tablepro-tests-no-such-key"), .none]
    )
    func sameKeyOverMissingServerKeyIsRefused(privateKeyPath: String?) async {
        let stages = SpyTunnelStages()

        await #expect(throws: SSHTunnelError.jumpHostSharedKeyMissing(host: Self.bastion.host)) {
            try await Self.create(
                stages: stages,
                authMethod: .privateKey,
                credentials: SSHTunnelCredentials(),
                privateKeyPath: privateKeyPath,
                jumpHosts: [Self.bastion],
                jumpHostCredentials: [Self.bastion.id: .sshServerKey]
            )
        }

        #expect(stages.connectCount == 0)
    }

    @Test("Same Key signs the hop in with a server key file that is on this device")
    func sameKeyTakesAServerKeyFile() async throws {
        let keyFile = FileManager.default.temporaryDirectory.appendingPathComponent("id-\(UUID().uuidString)")
        try Data("FILE KEY".utf8).write(to: keyFile)
        defer { try? FileManager.default.removeItem(at: keyFile) }
        let stages = SpyTunnelStages()

        _ = try await Self.create(
            stages: stages,
            authMethod: .privateKey,
            credentials: SSHTunnelCredentials(keyPassphrase: "file pass"),
            privateKeyPath: keyFile.path,
            jumpHosts: [Self.bastion],
            jumpHostCredentials: [Self.bastion.id: .sshServerKey]
        )

        #expect(stages.calls.filter { $0.hasPrefix("keyFile") } == [
            "keyFile \(Self.bastion.username) \(keyFile.path) file pass",
            "keyFile deploy \(keyFile.path) file pass"
        ])
    }

    @Test("A target with no username is refused before dialing, naming that host", arguments: [true, false])
    func emptyUsernameIsRefused(onTheHop: Bool) async {
        let stages = SpyTunnelStages()
        var hop = Self.bastion
        var config = Self.config(authMethod: .password)
        if onTheHop {
            hop.username = ""
        } else {
            config.username = " "
        }
        config.jumpHosts = [hop]

        await #expect(throws: SSHTunnelError.usernameMissing(host: onTheHop ? hop.host : config.host)) {
            try await SSHTunnelFactory.create(
                config: config,
                destination: .tcp(host: "db.internal", port: 5_432),
                credentials: Self.credentials(for: .password),
                jumpHostCredentials: [hop.id: .privateKey(key: "HOP KEY", passphrase: nil)],
                prompter: StubPrompter(answer: true),
                hostKeyStore: Self.temporaryHostKeyStore(),
                ensureLocalNetworkAccess: { _ in },
                makeStages: { stages }
            )
        }

        #expect(stages.connectCount == 0)
    }

    @Test(
        "A port outside 1 to 65535 is refused before dialing, so a channel never traps on it",
        arguments: ["hop", "server", "database"]
    )
    func outOfRangePortIsRefused(target: String) async {
        let stages = SpyTunnelStages()
        var hop = Self.bastion
        var config = Self.config(authMethod: .password)
        var remotePort = 5_432
        let named: String
        switch target {
        case "hop":
            hop.port = 2_147_483_648
            named = "Port 2147483648 of \(hop.host)"
        case "server":
            config.port = 70_000
            named = "Port 70000 of \(config.host)"
        default:
            remotePort = 0
            named = "Port 0 of db.internal"
        }
        config.jumpHosts = [hop]

        await #expect(throws: SSHTunnelError.connectionFailed("\(named) is out of range. Use a value between 1 and 65535.")) {
            try await SSHTunnelFactory.create(
                config: config,
                destination: .tcp(host: "db.internal", port: remotePort),
                credentials: Self.credentials(for: .password),
                jumpHostCredentials: [hop.id: .privateKey(key: "HOP KEY", passphrase: nil)],
                prompter: StubPrompter(answer: true),
                hostKeyStore: Self.temporaryHostKeyStore(),
                ensureLocalNetworkAccess: { _ in },
                makeStages: { stages }
            )
        }

        #expect(stages.connectCount == 0)
    }

    @Test("Local Network is checked for the first host the device dials", arguments: [true, false])
    func localNetworkProbesTheFirstHost(throughAHop: Bool) async throws {
        let localNetwork = LocalNetworkRecorder()

        _ = try await Self.create(
            stages: SpyTunnelStages(),
            authMethod: .password,
            jumpHosts: throughAHop ? [Self.bastion] : [],
            jumpHostCredentials: [Self.bastion.id: .privateKey(key: "HOP KEY", passphrase: nil)],
            localNetwork: localNetwork
        )

        #expect(localNetwork.probed == [throughAHop ? Self.bastion.host : "127.0.0.1"])
    }

    @Test("A hop that refuses its key is named in the error, which keeps the reason")
    func hopFailureNamesTheHop() async {
        let refusal = SSHTunnelError.authenticationFailed("In-memory key authentication failed (error -19)")
        let stages = SpyTunnelStages(failingAt: .authenticatePrivateKey, with: refusal)

        await #expect(throws: SSHTunnelError.jumpHostFailed(host: Self.bastion.host, reason: refusal.localizedDescription)) {
            try await Self.create(
                stages: stages,
                authMethod: .password,
                jumpHosts: [Self.bastion],
                jumpHostCredentials: [Self.bastion.id: .privateKey(key: "HOP KEY", passphrase: nil)]
            )
        }

        #expect(stages.discardCount == 1)
    }

    @Test("A channel the hop could not open names that hop")
    func jumpFailureNamesTheHopThatOpenedIt() async {
        let refusal = SSHTunnelError.channelOpenFailed("127.0.0.1:22: Channel open failure (administratively prohibited)")
        let stages = SpyTunnelStages(failingAt: .jump, with: refusal)

        await #expect(throws: SSHTunnelError.jumpHostFailed(host: Self.bastion.host, reason: refusal.localizedDescription)) {
            try await Self.create(
                stages: stages,
                authMethod: .password,
                jumpHosts: [Self.bastion],
                jumpHostCredentials: [Self.bastion.id: .privateKey(key: "HOP KEY", passphrase: nil)]
            )
        }

        #expect(stages.discardCount == 1)
    }

    @Test("A failure at the SSH server is not blamed on the hop before it")
    func serverFailureIsNotRenamed() async {
        let refusal = SSHTunnelError.authenticationFailed("Password authentication failed (error -18)")
        let stages = SpyTunnelStages(failingAt: .authenticatePassword, with: refusal)

        await #expect(throws: refusal) {
            try await Self.create(
                stages: stages,
                authMethod: .password,
                jumpHosts: [Self.bastion],
                jumpHostCredentials: [Self.bastion.id: .privateKey(key: "HOP KEY", passphrase: nil)]
            )
        }

        #expect(stages.discardCount == 1)
    }

    @Test("A hop's host key question keeps its own error")
    func hopHostKeyErrorIsNotRenamed() async {
        let stages = SpyTunnelStages()

        let error = await #expect(throws: SSHTunnelError.self) {
            try await Self.create(
                stages: stages,
                authMethod: .password,
                prompter: nil,
                jumpHosts: [Self.bastion],
                jumpHostCredentials: [Self.bastion.id: .privateKey(key: "HOP KEY", passphrase: nil)]
            )
        }

        guard case .some(.hostKeyUnverified) = error else {
            Issue.record("expected the host key error, got \(String(describing: error))")
            return
        }
        #expect(stages.discardCount == 1)
    }

    // MARK: - Sign-in on the device

    @Test("An SSH server set to SSH Agent on the Mac signs in with the key on this device")
    func agentServerSignsInWithTheDeviceKey() async throws {
        let stages = SpyTunnelStages()

        _ = try await Self.create(stages: stages, authMethod: .sshAgent)

        #expect(stages.calls.contains("key deploy PRIVATE KEY pass"))
        #expect(stages.discardCount == 0)
    }

    @Test("An SSH Agent server with no key on this device releases the session it already built")
    func agentWithNoKeyDiscardsOnce() async {
        let stages = SpyTunnelStages()

        await #expect(throws: SSHTunnelError.self) {
            try await Self.create(
                stages: stages,
                authMethod: .sshAgent,
                credentials: SSHTunnelCredentials(),
                privateKeyPath: nil
            )
        }

        #expect(stages.discardCount == 1)
    }

    // MARK: - Helpers

    private static let bastion = SSHJumpHost(host: "bastion.internal", port: 22, username: "jump")

    // A host key store on a fresh temporary path, so a trusted key never reaches the device's known_hosts.
    private static func create(
        stages: SpyTunnelStages,
        authMethod: SSHConfiguration.SSHAuthMethod,
        credentials: SSHTunnelCredentials? = nil,
        prompter: (any ConnectionPrompter)? = StubPrompter(answer: true),
        privateKeyPath: String? = "/tmp/id_ed25519",
        jumpHosts: [SSHJumpHost] = [],
        jumpHostCredentials: [UUID: JumpHostCredential] = [:],
        localNetwork: LocalNetworkRecorder = LocalNetworkRecorder()
    ) async throws -> SpyTunnel {
        var tunnelConfig = Self.config(authMethod: authMethod, privateKeyPath: privateKeyPath)
        tunnelConfig.jumpHosts = jumpHosts
        return try await SSHTunnelFactory.create(
            config: tunnelConfig,
            destination: .tcp(host: "db.internal", port: 5_432),
            credentials: credentials ?? Self.credentials(for: authMethod),
            jumpHostCredentials: jumpHostCredentials,
            prompter: prompter,
            hostKeyStore: temporaryHostKeyStore(),
            ensureLocalNetworkAccess: { localNetwork.probe($0) },
            makeStages: { stages }
        )
    }

    private static func temporaryHostKeyStore() -> HostKeyStore {
        HostKeyStore(
            filePath: FileManager.default.temporaryDirectory
                .appendingPathComponent("known_hosts-\(UUID().uuidString)").path
        )
    }

    private static func config(
        authMethod: SSHConfiguration.SSHAuthMethod,
        privateKeyPath: String? = "/tmp/id_ed25519"
    ) -> SSHConfiguration {
        SSHConfiguration(
            host: "127.0.0.1",
            port: 22,
            username: "deploy",
            authMethod: authMethod,
            privateKeyPath: privateKeyPath
        )
    }

    private static func chainConfig(authMethod: SSHConfiguration.SSHAuthMethod) -> SSHConfiguration {
        SSHConfiguration(host: "db-ssh.internal", port: nil, username: "deploy", authMethod: authMethod)
    }

    private static func credentials(for authMethod: SSHConfiguration.SSHAuthMethod) -> SSHTunnelCredentials {
        switch authMethod {
        case .privateKey, .sshAgent:
            return SSHTunnelCredentials(keyPassphrase: "pass", privateKey: "PRIVATE KEY")
        default:
            return SSHTunnelCredentials(password: "secret")
        }
    }
}

nonisolated struct SpyFailure: Error {}

nonisolated final class StubPrompter: ConnectionPrompter, Sendable {
    private let answer: Bool

    init(answer: Bool) {
        self.answer = answer
    }

    func confirm(_ question: ConnectionQuestion) async -> Bool {
        answer
    }
}

nonisolated final class HostKeyQuestionRecorder: ConnectionPrompter, Sendable {
    private let asked = OSAllocatedUnfairLock<[String]>(initialState: [])

    var questions: [String] { asked.withLock { $0 } }

    func confirm(_ question: ConnectionQuestion) async -> Bool {
        switch question {
        case .unknownHostKey(let host, let port, _, _), .changedHostKey(let host, let port, _, _):
            asked.withLock { $0.append("\(host):\(port)") }
        }
        return true
    }
}

nonisolated final class LocalNetworkRecorder: Sendable {
    private let hosts = OSAllocatedUnfairLock<[String]>(initialState: [])

    var probed: [String] { hosts.withLock { $0 } }

    func probe(_ host: String) {
        hosts.withLock { $0.append(host) }
    }
}

// Stands in for the libssh2 session builder with no I/O, so every failure path is reachable offline.
nonisolated final class SpyTunnelStages: SSHTunnelStages, Sendable {
    nonisolated enum Step: CaseIterable, Sendable {
        case connect
        case jump
        case handshake
        case hostKey
        case authenticatePassword
        case authenticatePrivateKey
        case authenticateNone
        case beginForwarding

        var authMethod: SSHConfiguration.SSHAuthMethod {
            switch self {
            case .authenticatePrivateKey: return .privateKey
            case .authenticateNone: return .none
            default: return .password
            }
        }
    }

    private struct State {
        var discards = 0
        var connects = 0
        var destination: SSHForwardDestination?
        var suspended = false
        var calls: [String] = []
    }

    let tunnel = SpyTunnel()

    private let failingAt: Step?
    private let failure: any Error
    private let suspendingAt: Step?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(failingAt: Step? = nil, with failure: any Error = SpyFailure(), suspendingAt: Step? = nil) {
        self.failingAt = failingAt
        self.failure = failure
        self.suspendingAt = suspendingAt
    }

    var discardCount: Int { state.withLock { $0.discards } }

    var connectCount: Int { state.withLock { $0.connects } }

    var forwardedTo: SSHForwardDestination? { state.withLock { $0.destination } }

    var calls: [String] { state.withLock { $0.calls } }

    func waitUntilSuspended() async {
        while !state.withLock({ $0.suspended }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func connect(host: String, port: Int) async throws {
        state.withLock { $0.connects += 1 }
        try await run(.connect, "connect \(host):\(port)")
    }

    func jump(toHost host: String, port: Int) async throws {
        try await run(.jump, "jump \(host):\(port)")
    }

    func handshake() async throws {
        try await run(.handshake, "handshake")
    }

    func hostKey() async throws -> (keyData: Data, keyType: String) {
        try await run(.hostKey, "hostKey")
        return (Data([0x01, 0x02]), "ssh-ed25519")
    }

    func authenticatePassword(username: String, password: String) async throws {
        try await run(.authenticatePassword, "password \(username)")
    }

    func authenticatePublicKey(username: String, keyPath: String, passphrase: String?) async throws {
        try await run(.authenticatePrivateKey, "keyFile \(username) \(keyPath) \(passphrase ?? "-")")
    }

    func authenticatePublicKeyFromMemory(username: String, keyContent: String, passphrase: String?) async throws {
        try await run(.authenticatePrivateKey, "key \(username) \(keyContent) \(passphrase ?? "-")")
    }

    func authenticateNone(username: String) async throws {
        try await run(.authenticateNone, "none \(username)")
    }

    func beginForwarding(destination: SSHForwardDestination) async throws -> SpyTunnel {
        try await run(.beginForwarding, "forward")
        state.withLock { $0.destination = destination }
        return tunnel
    }

    func discard() {
        state.withLock { $0.discards += 1 }
    }

    private func run(_ step: Step, _ call: String) async throws {
        state.withLock { $0.calls.append(call) }
        if step == suspendingAt {
            state.withLock { $0.suspended = true }
            try await Task.sleep(for: .seconds(30))
        }
        if step == failingAt { throw failure }
    }
}

nonisolated final class SpyTunnel: Sendable {}
