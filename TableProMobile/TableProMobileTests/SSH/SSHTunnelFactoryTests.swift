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

        await #expect(throws: SpyFailure.self) {
            try await Self.create(stages: stages, authMethod: step.authMethod)
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
            try await Self.create(stages: stages, authMethod: .sshAgent)
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

    @Test("A connection through a jump host is refused before anything is dialled")
    func jumpHostsAreRefused() async {
        let stages = SpyTunnelStages()
        var config = Self.config(authMethod: .password)
        config.jumpHosts = [SSHJumpHost(host: "bastion.internal", port: 22, username: "jump")]

        await #expect(throws: SSHTunnelError.jumpHostsUnsupported) {
            try await SSHTunnelFactory.create(
                config: config,
                remoteHost: "db.internal",
                remotePort: 5_432,
                credentials: Self.credentials(for: .password),
                prompter: StubPrompter(answer: true),
                hostKeyStore: Self.temporaryHostKeyStore(),
                makeStages: { stages }
            )
        }

        #expect(stages.connectCount == 0)
        #expect(stages.discardCount == 0)
    }

    /// 127.0.0.1 so `LocalNetworkPermission` returns without opening a connection, and a host key
    /// store on a fresh temporary path so a trusted key never reaches the device's known_hosts.
    private static func create(
        stages: SpyTunnelStages,
        authMethod: SSHConfiguration.SSHAuthMethod,
        credentials: SSHTunnelCredentials? = nil,
        prompter: (any ConnectionPrompter)? = StubPrompter(answer: true),
        privateKeyPath: String? = "/tmp/id_ed25519"
    ) async throws -> SpyTunnel {
        try await SSHTunnelFactory.create(
            config: config(authMethod: authMethod, privateKeyPath: privateKeyPath),
            remoteHost: "db.internal",
            remotePort: 5_432,
            credentials: credentials ?? Self.credentials(for: authMethod),
            prompter: prompter,
            hostKeyStore: temporaryHostKeyStore(),
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

    private static func credentials(for authMethod: SSHConfiguration.SSHAuthMethod) -> SSHTunnelCredentials {
        switch authMethod {
        case .privateKey:
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

/// Stands in for the libssh2 session builder. It performs no I/O, so every failure path the
/// factory has is reachable with no SSH server and no network.
nonisolated final class SpyTunnelStages: SSHTunnelStages, Sendable {
    nonisolated enum Step: CaseIterable, Sendable {
        case connect
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
    }

    let tunnel = SpyTunnel()

    private let failingAt: Step?
    private let suspendingAt: Step?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(failingAt: Step? = nil, suspendingAt: Step? = nil) {
        self.failingAt = failingAt
        self.suspendingAt = suspendingAt
    }

    var discardCount: Int { state.withLock { $0.discards } }

    var connectCount: Int { state.withLock { $0.connects } }

    var forwardedTo: SSHForwardDestination? { state.withLock { $0.destination } }

    func waitUntilSuspended() async {
        while !state.withLock({ $0.suspended }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func connect(host: String, port: Int) async throws {
        state.withLock { $0.connects += 1 }
        try await run(.connect)
    }

    func handshake() async throws {
        try await run(.handshake)
    }

    func hostKey() async throws -> (keyData: Data, keyType: String) {
        try await run(.hostKey)
        return (Data([0x01, 0x02]), "ssh-ed25519")
    }

    func authenticatePassword(username: String, password: String) async throws {
        try await run(.authenticatePassword)
    }

    func authenticatePublicKey(username: String, keyPath: String, passphrase: String?) async throws {
        try await run(.authenticatePrivateKey)
    }

    func authenticatePublicKeyFromMemory(username: String, keyContent: String, passphrase: String?) async throws {
        try await run(.authenticatePrivateKey)
    }

    func authenticateNone(username: String) async throws {
        try await run(.authenticateNone)
    }

    func beginForwarding(destination: SSHForwardDestination) async throws -> SpyTunnel {
        try await run(.beginForwarding)
        state.withLock { $0.destination = destination }
        return tunnel
    }

    func discard() {
        state.withLock { $0.discards += 1 }
    }

    private func run(_ step: Step) async throws {
        if step == suspendingAt {
            state.withLock { $0.suspended = true }
            try await Task.sleep(for: .seconds(30))
        }
        if step == failingAt { throw SpyFailure() }
    }
}

nonisolated final class SpyTunnel: Sendable {}
