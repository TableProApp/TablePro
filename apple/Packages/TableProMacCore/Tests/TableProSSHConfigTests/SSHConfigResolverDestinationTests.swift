//
//  SSHConfigResolverDestinationTests.swift
//  TableProTests
//

import Foundation
import TableProSSHTransport
import Testing

@testable import TableProSSHConfig

struct SSHConfigResolverDestinationTests {
    private final class CommandRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        func record(_ command: String) {
            lock.lock()
            defer { lock.unlock() }
            commands.append(command)
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }
    }

    private static let document = SSHConfigParser.parseDocumentContent(
        """
        Match host *.internal.example !exec "nc -z -w 1 %h %p"
            ProxyJump bastion.example.com
        Match exec "test %r = deploy"
            IdentityFile ~/.ssh/deploy
        """
    )

    private func environment(
        _ recorder: CommandRecorder,
        canonicalize: @escaping @Sendable (String, SSHCanonicalizationOptions) -> String? = { host, _ in host }
    ) -> ResolverEnvironment {
        ResolverEnvironment(
            runShell: { command in
                recorder.record(command)
                return true
            },
            canonicalize: canonicalize,
            currentLocalUser: { "tester" },
            localHostname: { "Mac" }
        )
    }

    private func resolve(
        host: String,
        username: String = "",
        document: SSHConfigDocument = Self.document
    ) -> (target: ResolvedSSHTarget, commands: [String]) {
        let recorder = CommandRecorder()
        let target = SSHConfigResolver.resolve(
            SSHConfiguration(enabled: true, host: host, username: username, authMethod: .privateKey),
            document: document,
            env: environment(recorder)
        )
        return (target, recorder.recorded)
    }

    @Test("A tunnel host with shell syntax never reaches the Match exec shell", arguments: [
        "db$(touch /tmp/pwned).internal.example",
        "db`touch /tmp/pwned`.internal.example",
        "db;touch /tmp/pwned;.internal.example",
        "db|sh.internal.example",
        "db.internal.example\\",
        "db\n.internal.example",
        "-oProxyCommand=touch /tmp/pwned",
    ])
    func hostileHostIsNotExpandedIntoACommand(host: String) {
        let (target, commands) = resolve(host: host, username: "deploy")
        #expect(commands.isEmpty)
        #expect(target.expansionFailure == .invalidDestination(.host(host)))
        #expect(target.identityFiles.isEmpty)
    }

    @Test("A tunnel user with shell syntax never reaches the Match exec shell", arguments: [
        "x; touch /tmp/pwned; true",
        "x$(touch /tmp/pwned)",
        "x\ntouch /tmp/pwned",
        "-oProxyCommand=touch /tmp/pwned",
        "x -oProxyCommand=touch",
        "x\\",
        "alice \\-oProxyCommand=printf\\ probe",
        "\\-oProxyCommand=printf",
        "x$IFS-oProxyCommand=printf",
        "backup$",
    ])
    func hostileUserIsNotExpandedIntoACommand(username: String) {
        let (target, commands) = resolve(host: "db.example.com", username: username)
        #expect(commands.isEmpty)
        #expect(target.expansionFailure == .invalidDestination(.user(username)))
        #expect(target.identityFiles.isEmpty)
    }

    @Test("A user name ssh accepts still connects when no Match exec substitutes it", arguments: [
        "first last", "alice \\-oProxyCommand=printf", "backup$"
    ])
    func userWithASpaceResolvesWhenNotSubstituted(username: String) {
        let document = SSHConfigParser.parseDocumentContent("""
            Match exec "probe %h %%r"
                Port 2222
            """)
        let (target, commands) = resolve(host: "db.example.com", username: username, document: document)
        #expect(commands == ["probe db.example.com %r"])
        #expect(target.expansionFailure == nil)
        #expect(target.port == 2_222)
    }

    @Test("A user with a space stays one word inside a quoted %r")
    func userWithASpaceIsSubstituted() {
        let document = SSHConfigParser.parseDocumentContent("""
            Match exec "test '%r' = 'first last'"
                Port 2222
            """)
        let (target, commands) = resolve(host: "db.example.com", username: "first last", document: document)
        #expect(commands == ["test 'first last' = 'first last'"])
        #expect(target.expansionFailure == nil)
        #expect(target.port == 2_222)
    }

    @Test("An ordinary host and user are still probed")
    func ordinaryNamesAreProbed() {
        let (target, commands) = resolve(host: "db1.internal.example", username: "deploy")
        #expect(commands == ["nc -z -w 1 db1.internal.example 22", "test deploy = deploy"])
        #expect(target.expansionFailure == nil)
        #expect(target.identityFiles.map { $0.hasSuffix("/.ssh/deploy") } == [true])
    }

    @Test("Names ssh accepts are accepted", arguments: [
        ("fe80::1%en0", "deploy"),
        ("db.example.com", "DOMAIN\\deploy"),
        ("db.example.com", "bob,evil.example.net"),
    ])
    func ordinaryNamesResolve(host: String, username: String) {
        let (target, _) = resolve(host: host, username: username)
        #expect(target.expansionFailure == nil)
        #expect(target.host == host)
        #expect(target.username == username)
    }

    @Test("A jump host from the form is checked the same way")
    func jumpHostIsChecked() {
        let recorder = CommandRecorder()
        let host = "bastion$(touch /tmp/pwned).internal.example"
        let target = SSHConfigResolver.resolve(
            SSHJumpHost(host: host, username: "deploy"),
            document: Self.document,
            env: environment(recorder)
        )
        #expect(recorder.recorded.isEmpty)
        #expect(target.expansionFailure == .invalidDestination(.host(host)))
    }

    @Test("A HostName substitution with shell syntax never reaches the Match exec shell")
    func substitutedHostIsChecked() {
        let document = SSHConfigParser.parseDocumentContent(
            """
            Host alias
                HostName db;id
            Match exec "probe %h"
                User deploy
            """
        )
        let (target, commands) = resolve(host: "alias", document: document)
        #expect(commands.isEmpty)
        #expect(target.expansionFailure == .invalidDestination(.host("db;id")))
    }

    @Test("A canonical name from DNS with shell syntax never reaches the second-pass Match exec")
    func canonicalHostIsChecked() {
        let document = SSHConfigParser.parseDocumentContent(
            """
            CanonicalizeHostname yes
            CanonicalDomains corp.example
            Match canonical exec "probe %h"
                User deploy
            """
        )
        let recorder = CommandRecorder()
        let target = SSHConfigResolver.resolve(
            SSHConfiguration(enabled: true, host: "db", authMethod: .privateKey),
            document: document,
            env: environment(recorder) { _, _ in "db$(id).corp.example" }
        )
        #expect(recorder.recorded.isEmpty)
        #expect(target.expansionFailure == .invalidDestination(.host("db$(id).corp.example")))
    }
}
