//
//  AgentAuthenticationReportingTests.swift
//  TableProTests
//
//  SSH Agent auth used to end in TablePro's own passphrase prompt for a key the user never
//  chose: the chain fell through to `~/.ssh/id_*` whenever the agent produced nothing, and the
//  agent's own failure was then buried by the keyboard-interactive step that followed, which
//  reported "SSH password rejected" on a connection with no password (#2583).
//
//  The agent cases run against a real unix socket speaking the agent protocol, because the
//  distinction under test is exactly what libssh2 does with the bytes on that socket.
//

import Foundation
import Testing

import CLibSSH2

@testable import TablePro

/// Minimal ssh-agent that answers `SSH_AGENTC_REQUEST_IDENTITIES` with a fixed identity list.
private final class FakeSSHAgent: @unchecked Sendable {
    let path: String
    private let listenFD: Int32
    private let identityBlobs: [(blob: [UInt8], comment: String)]
    private var thread: Thread?

    init?(identities: [(blob: [UInt8], comment: String)]) {
        identityBlobs = identities

        // sun_path is 104 bytes, and the socket has to sit somewhere every test run can write.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-agent-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("agent.sock").path

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(listenFD)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(listenFD, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenFD, 4) == 0 else {
            Darwin.close(listenFD)
            return nil
        }

        let thread = Thread { [weak self] in self?.serve() }
        thread.start()
        self.thread = thread
    }

    func stop() {
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()
        )
    }

    private func serve() {
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            handle(clientFD)
            Darwin.close(clientFD)
        }
    }

    private func handle(_ clientFD: Int32) {
        while let request = readFrame(clientFD), let type = request.first {
            let sshAgentcRequestIdentities: UInt8 = 11
            guard type == sshAgentcRequestIdentities else {
                let sshAgentFailure: UInt8 = 5
                writeFrame(clientFD, [sshAgentFailure])
                continue
            }
            writeFrame(clientFD, identitiesAnswer())
        }
    }

    private func identitiesAnswer() -> [UInt8] {
        let sshAgentIdentitiesAnswer: UInt8 = 12
        var payload: [UInt8] = [sshAgentIdentitiesAnswer]
        payload += Self.uint32(UInt32(identityBlobs.count))
        for identity in identityBlobs {
            payload += Self.string(identity.blob)
            payload += Self.string(Array(identity.comment.utf8))
        }
        return payload
    }

    private static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func string(_ bytes: [UInt8]) -> [UInt8] {
        uint32(UInt32(bytes.count)) + bytes
    }

    private func readFrame(_ fd: Int32) -> [UInt8]? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16)
            | (UInt32(header[2]) << 8) | UInt32(header[3])
        guard length > 0, length < 64 * 1024 else { return nil }
        return readExactly(fd, Int(length))
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let read: Int = buffer.withUnsafeMutableBytes { destination in
                guard let base = destination.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: filled), count - filled)
            }
            guard read > 0 else { return nil }
            filled += read
        }
        return buffer
    }

    private func writeFrame(_ fd: Int32, _ payload: [UInt8]) {
        let frame = Self.uint32(UInt32(payload.count)) + payload
        var written = 0
        while written < frame.count {
            let sent: Int = frame.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: written), frame.count - written)
            }
            guard sent > 0 else { return }
            written += sent
        }
    }
}

/// A session with no transport. `libssh2_agent_*` never touches one, and
/// `libssh2_userauth_authenticated` only reads a state flag, so the agent and composite paths
/// under test run without an SSH server.
private func withTransportlessSession<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    // libssh2_init uses global state and must not be called concurrently, and Swift Testing runs
    // sibling cases in parallel, so this goes through the app's one lazy initializer.
    _ = LibSSH2TunnelFactory.initialized
    let session = try #require(tablepro_libssh2_session_init())
    defer { libssh2_session_free(session) }
    return try body(session)
}

@Suite("AgentAuthenticator failure reasons", .serialized)
struct AgentAuthenticatorFailureTests {
    @Test("A socket path nothing is listening on reports the agent as unreachable (#2583)")
    func missingSocketReportsUnavailable() throws {
        let missingPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-agent-absent.sock").path

        try withTransportlessSession { session in
            #expect(throws: SSHTunnelError.authenticationFailed(reason: .agentUnavailable(.agentSocketSetting))) {
                try AgentAuthenticator(socketPath: missingPath, socketOrigin: .agentSocketSetting)
                    .authenticate(session: session, username: "alice")
            }
        }
    }

    @Test("An agent that answers with an empty key list reports no identities (#2583)")
    func emptyAgentReportsNoIdentities() throws {
        let agent = try #require(FakeSSHAgent(identities: []))
        defer { agent.stop() }

        try withTransportlessSession { session in
            #expect(throws: SSHTunnelError.authenticationFailed(reason: .agentNoIdentities(.identityAgentDirective))) {
                try AgentAuthenticator(socketPath: agent.path, socketOrigin: .identityAgentDirective)
                    .authenticate(session: session, username: "alice")
            }
        }
    }

    /// The reported case: a 1Password agent holding one key per server, and an `IdentityFile`
    /// naming a key that is not in it. Offering all thirty is what `MaxAuthTries 6` disconnects
    /// on, so nothing should be offered at all and the message should say why (#2601).
    @Test("IdentitiesOnly with no agent key matching the identity file offers nothing (#2601)")
    func identitiesOnlyWithoutAMatchReportsNoMatchingIdentity() throws {
        let agent = try #require(FakeSSHAgent(identities: Self.identities(count: 30, from: 1)))
        defer { agent.stop() }
        let identityFile = try Self.writeIdentityFile(seed: 200)
        defer { try? FileManager.default.removeItem(at: identityFile.deletingLastPathComponent()) }

        try withTransportlessSession { session in
            #expect(
                throws: SSHTunnelError.authenticationFailed(reason: .agentNoMatchingIdentity(.agentSocketSetting))
            ) {
                try AgentAuthenticator(
                    socketPath: agent.path,
                    socketOrigin: .agentSocketSetting,
                    identityFiles: [identityFile.path],
                    identitiesOnly: true
                ).authenticate(session: session, username: "alice")
            }
        }
    }

    /// The other half: a match is offered, so the run gets as far as `libssh2_agent_userauth` and
    /// fails on the missing transport rather than on identity selection.
    @Test("IdentitiesOnly with a matching identity file offers that key (#2601)")
    func identitiesOnlyWithAMatchReachesUserauth() throws {
        let agent = try #require(FakeSSHAgent(identities: Self.identities(count: 30, from: 1)))
        defer { agent.stop() }
        let identityFile = try Self.writeIdentityFile(seed: 20)
        defer { try? FileManager.default.removeItem(at: identityFile.deletingLastPathComponent()) }

        try withTransportlessSession { session in
            let reason = Self.failureReason {
                try AgentAuthenticator(
                    socketPath: agent.path,
                    socketOrigin: .agentSocketSetting,
                    identityFiles: [identityFile.path],
                    identitiesOnly: true
                ).authenticate(session: session, username: "alice")
            }

            #expect(reason != .agentNoMatchingIdentity(.agentSocketSetting))
            #expect(reason != .agentNoIdentities(.agentSocketSetting))
            #expect(reason != nil)
        }
    }

    /// An identity file that names nothing readable is a typo or a moved key, not "no preference".
    /// Quietly offering all thirty keys there hands back the `MaxAuthTries` failure the file was
    /// set to avoid, with nothing to say why (#2601).
    @Test("IdentitiesOnly with an unreadable identity file refuses rather than offering every key (#2601)")
    func identitiesOnlyWithAnUnreadableIdentityFileRefuses() throws {
        let agent = try #require(FakeSSHAgent(identities: Self.identities(count: 30, from: 1)))
        defer { agent.stop() }
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-absent-\(UUID().uuidString).pub").path

        try withTransportlessSession { session in
            #expect(throws: SSHTunnelError.authenticationFailed(reason: .agentIdentityFileUnreadable)) {
                try AgentAuthenticator(
                    socketPath: agent.path,
                    socketOrigin: .agentSocketSetting,
                    identityFiles: [absent],
                    identitiesOnly: true
                ).authenticate(session: session, username: "alice")
            }
        }
    }

    /// Without `IdentitiesOnly`, `ssh` also falls back to the rest of the agent, so an unreadable
    /// identity file must not turn a working connection into a hard failure.
    @Test("An unreadable identity file without IdentitiesOnly still offers the agent's keys (#2601)")
    func unreadableIdentityFileWithoutIdentitiesOnlyStillOffersKeys() throws {
        let agent = try #require(FakeSSHAgent(identities: Self.identities(count: 3, from: 1)))
        defer { agent.stop() }
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-absent-\(UUID().uuidString).pub").path

        try withTransportlessSession { session in
            let reason = Self.failureReason {
                try AgentAuthenticator(
                    socketPath: agent.path,
                    socketOrigin: .agentSocketSetting,
                    identityFiles: [absent],
                    identitiesOnly: false
                ).authenticate(session: session, username: "alice")
            }

            #expect(reason != .agentIdentityFileUnreadable)
            #expect(reason != .agentNoMatchingIdentity(.agentSocketSetting))
        }
    }

    /// No identity file means no preference, which has to stay exactly what it was: every key the
    /// agent holds, in the agent's order.
    @Test("An agent with no identity file configured still offers its keys (#2601)")
    func noIdentityFileOffersEveryKey() throws {
        let agent = try #require(FakeSSHAgent(identities: Self.identities(count: 3, from: 1)))
        defer { agent.stop() }

        try withTransportlessSession { session in
            let reason = Self.failureReason {
                try AgentAuthenticator(socketPath: agent.path, socketOrigin: .agentSocketSetting)
                    .authenticate(session: session, username: "alice")
            }

            #expect(reason != .agentNoMatchingIdentity(.agentSocketSetting))
            #expect(reason != .agentNoIdentities(.agentSocketSetting))
        }
    }

    private static func identities(count: Int, from first: UInt8) -> [(blob: [UInt8], comment: String)] {
        (0 ..< count).map { offset in
            let seed = first &+ UInt8(offset)
            return (
                blob: [UInt8](SSHPublicKeyFixture.blob(type: "ssh-ed25519", seed: seed)),
                comment: "key-\(offset + 1)"
            )
        }
    }

    private static func writeIdentityFile(seed: UInt8) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tp-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("selected.pub")
        try SSHPublicKeyFixture.line(type: "ssh-ed25519", seed: seed)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func failureReason(_ body: () throws -> Void) -> AuthFailureReason? {
        do {
            try body()
            return nil
        } catch let error as SSHTunnelError {
            guard case .authenticationFailed(let reason) = error else { return nil }
            return reason
        } catch {
            return nil
        }
    }
}

private struct ThrowingAuthenticator: SSHAuthenticator {
    let reason: AuthFailureReason

    func authenticate(session: OpaquePointer, username: String) throws {
        throw SSHTunnelError.authenticationFailed(reason: reason)
    }
}

@Suite("CompositeAuthenticator failure reporting")
struct CompositeAuthenticatorFailureReportingTests {
    private func failureReason(
        of authenticators: [any SSHAuthenticator],
        endsChainOn: Set<AuthFailureReason> = []
    ) throws -> AuthFailureReason? {
        try withTransportlessSession { session in
            do {
                try CompositeAuthenticator(authenticators: authenticators, endsChainOn: endsChainOn)
                    .authenticate(session: session, username: "alice")
                return nil
            } catch let error as SSHTunnelError {
                guard case .authenticationFailed(let reason) = error else { return nil }
                return reason
            }
        }
    }

    @Test("A method the server never engaged does not bury the agent's failure (#2583)")
    func unavailableMethodDoesNotBuryAgentFailure() throws {
        let reason = try failureReason(of: [
            ThrowingAuthenticator(reason: .agentNoIdentities(.environment)),
            ThrowingAuthenticator(reason: .methodUnavailable),
        ])

        #expect(reason == .agentNoIdentities(.environment))
    }

    @Test("A second factor the server did challenge still wins (#1018)")
    func engagedSecondFactorStillWins() throws {
        let reason = try failureReason(of: [
            ThrowingAuthenticator(reason: .privateKey),
            ThrowingAuthenticator(reason: .verificationCode),
        ])

        #expect(reason == .verificationCode)
    }

    @Test("An unreachable agent ends the chain instead of letting a second factor prompt (#2583)")
    func unreachableAgentEndsTheChain() throws {
        final class Spy: SSHAuthenticator, @unchecked Sendable {
            var ran = false
            func authenticate(session: OpaquePointer, username: String) throws {
                ran = true
                throw SSHTunnelError.authenticationFailed(reason: .keyboardInteractive)
            }
        }
        let secondFactor = Spy()

        let reason = try failureReason(
            of: [ThrowingAuthenticator(reason: .agentUnavailable(.agentSocketSetting)), secondFactor],
            endsChainOn: [.agentUnavailable(.agentSocketSetting)]
        )

        #expect(reason == .agentUnavailable(.agentSocketSetting))
        #expect(!secondFactor.ran)
    }

    @Test("An agent the server refused still lets the second factor run (#1920)")
    func rejectedAgentKeepsTheSecondFactor() throws {
        let reason = try failureReason(
            of: [ThrowingAuthenticator(reason: .agentRejected), ThrowingAuthenticator(reason: .verificationCode)],
            endsChainOn: [.agentUnavailable(.agentSocketSetting), .agentNoIdentities(.agentSocketSetting)]
        )

        #expect(reason == .verificationCode)
    }

    @Test("An unavailable method is still reported when it is the only failure")
    func unavailableMethodSurvivesAlone() throws {
        let reason = try failureReason(of: [ThrowingAuthenticator(reason: .methodUnavailable)])

        #expect(reason == .methodUnavailable)
    }

    @Test("A user cancellation aborts the chain before any later step runs")
    func cancellationAbortsTheChain() throws {
        let reason = try failureReason(of: [
            ThrowingAuthenticator(reason: .cancelled),
            ThrowingAuthenticator(reason: .password),
        ])

        #expect(reason == .cancelled)
    }
}

@Suite("KeyboardInteractiveContext failure reason")
struct KeyboardInteractiveFailureReasonTests {
    private final class SilentPromptProvider: KeyboardInteractivePromptProvider, @unchecked Sendable {
        func provideResponses(for challenge: KeyboardInteractiveChallenge, attempt: Int) throws -> [String] {
            []
        }
    }

    private func context(password: String? = nil) -> KeyboardInteractiveContext {
        KeyboardInteractiveContext(
            password: password,
            totpProvider: nil,
            promptProvider: SilentPromptProvider()
        )
    }

    @Test("A server that issued no prompt reports the method as unavailable, not a bad password (#2583)")
    func noPromptIsNotAPasswordRejection() {
        #expect(context(password: "hunter2").failureReason == .methodUnavailable)
    }

    @Test("A password answered from the fast path reports a password rejection (#1005)")
    func answeredPasswordReportsPassword() {
        let ctx = context(password: "hunter2")
        _ = ctx.responses(name: "", instruction: "", prompts: [KeyboardInteractivePrompt(text: "Password:", echo: false)])

        #expect(ctx.failureReason == .password)
    }
}
