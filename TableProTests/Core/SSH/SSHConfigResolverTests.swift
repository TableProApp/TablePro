//
//  SSHConfigResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH config resolver")
struct SSHConfigResolverTests {
    private func makeConfig(
        host: String,
        port: Int? = nil,
        username: String = "",
        privateKeyPath: String = "",
        agentSocketPath: String = "",
        jumpHosts: [SSHJumpHost] = []
    ) -> SSHConfiguration {
        SSHConfiguration(
            enabled: true,
            host: host,
            port: port,
            username: username,
            authMethod: .privateKey,
            privateKeyPath: privateKeyPath,
            agentSocketPath: agentSocketPath,
            jumpHosts: jumpHosts
        )
    }

    private static let stubEnv = ResolverEnvironment(
        runShell: { _ in true },
        canonicalize: { host, _ in host },
        currentLocalUser: { "tester" }
    )

    @Test("Alias with HostName resolves to real host")
    func aliasResolvesHostName() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host aia-bastion
            HostName 10.0.0.5
            User ubuntu
            Port 2200
        """)
        let resolved = SSHConfigResolver.resolve(makeConfig(host: "aia-bastion"), document: document, env: Self.stubEnv)
        #expect(resolved.host == "10.0.0.5")
        #expect(resolved.port == 2200)
        #expect(resolved.username == "ubuntu")
    }

    @Test("Alias without HostName keeps the alias as host")
    func aliasWithoutHostName() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host my-server
            User deploy
        """)
        let resolved = SSHConfigResolver.resolve(makeConfig(host: "my-server"), document: document, env: Self.stubEnv)
        #expect(resolved.host == "my-server")
        #expect(resolved.username == "deploy")
    }

    @Test("Explicit form port overrides ssh config Port")
    func explicitPortWins() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName 1.2.3.4
            Port 2200
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias", port: 9999),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.port == 9999)
    }

    @Test("Unset form port falls back to ssh config Port")
    func unsetPortFallsBack() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName 1.2.3.4
            Port 2200
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.port == 2200)
    }

    @Test("Explicit form port 22 overrides ssh config non-22 Port")
    func explicitPort22OverridesConfig() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName 1.2.3.4
            Port 2200
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias", port: 22),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.port == 22)
    }

    @Test("Explicit username overrides ssh config User")
    func explicitUsernameWins() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName 1.2.3.4
            User configuser
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias", username: "formuser"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "formuser")
    }

    @Test("Explicit privateKeyPath overrides ssh config IdentityFile")
    func explicitKeyPathWins() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName 1.2.3.4
            IdentityFile ~/.ssh/from_config
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias", privateKeyPath: "~/.ssh/from_form"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.identityFiles == ["~/.ssh/from_form"])
    }

    @Test("Empty privateKeyPath uses ssh config IdentityFile")
    func emptyKeyPathFallsBack() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName 1.2.3.4
            IdentityFile ~/.ssh/test_key
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.identityFiles.count == 1)
        #expect(resolved.identityFiles.first?.hasSuffix("/.ssh/test_key") == true)
    }

    @Test("Multiple IdentityFile directives accumulate in order")
    func identityFilesAccumulate() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName 1.2.3.4
            IdentityFile ~/.ssh/key1
            IdentityFile ~/.ssh/key2
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.identityFiles.count == 2)
        #expect(resolved.identityFiles[0].hasSuffix("/.ssh/key1"))
        #expect(resolved.identityFiles[1].hasSuffix("/.ssh/key2"))
    }

    @Test("First-match-wins for repeated non-list directives")
    func firstMatchWinsForPort() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName 1.2.3.4
            Port 2200
        Host alias
            Port 9999
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.port == 2200)
    }

    @Test("Glob Host pattern matches")
    func globMatches() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host *.aws
            User awsadmin
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "db.aws"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "awsadmin")
    }

    @Test("ProxyJump injected when form has no jump hosts")
    func proxyJumpInjected() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host target
            HostName final.example.com
            ProxyJump bastion@10.0.0.1:2200
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "target"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.proxyJump.count == 1)
        #expect(resolved.proxyJump[0].host == "10.0.0.1")
        #expect(resolved.proxyJump[0].port == 2200)
        #expect(resolved.proxyJump[0].username == "bastion")
    }

    @Test("ProxyJump suppressed when form has explicit jump hosts")
    func proxyJumpSuppressed() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host target
            HostName final.example.com
            ProxyJump configbastion
        """)
        var formJump = SSHJumpHost()
        formJump.host = "form-bastion"
        formJump.username = "user"
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "target", jumpHosts: [formJump]),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.proxyJump.isEmpty)
    }

    @Test("Match host evaluates against post-substitution hostname")
    func matchHost() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName real.example.com
        Match host real.example.com
            User matched
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "matched")
    }

    @Test("Match originalhost evaluates against the form host")
    func matchOriginalHost() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host alias
            HostName real.example.com
        Match originalhost alias
            User originalmatched
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "originalmatched")
    }

    @Test("Match all is unconditional")
    func matchAll() {
        let document = SSHConfigParser.parseDocumentContent("""
        Match all
            User globaluser
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "anything"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "globaluser")
    }

    @Test("Match exec evaluates command")
    func matchExec() {
        let document = SSHConfigParser.parseDocumentContent("""
        Match exec "test"
            User matched
        """)
        let trueEnv = ResolverEnvironment(
            runShell: { _ in true },
            canonicalize: { host, _ in host },
            currentLocalUser: { "tester" }
        )
        let trueResolved = SSHConfigResolver.resolve(
            makeConfig(host: "anything"),
            document: document,
            env: trueEnv
        )
        #expect(trueResolved.username == "matched")

        let falseEnv = ResolverEnvironment(
            runShell: { _ in false },
            canonicalize: { host, _ in host },
            currentLocalUser: { "tester" }
        )
        let falseResolved = SSHConfigResolver.resolve(
            makeConfig(host: "anything"),
            document: document,
            env: falseEnv
        )
        #expect(falseResolved.username == "")
    }

    @Test("Match canonical only applies on second pass after canonicalization")
    func matchCanonical() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host short
            HostName short
            CanonicalizeHostname yes
            CanonicalDomains example.com
        Match canonical host short.example.com
            User canonicalized
        """)
        let canonicalEnv = ResolverEnvironment(
            runShell: { _ in true },
            canonicalize: { _, _ in "short.example.com" },
            currentLocalUser: { "tester" }
        )
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "short"),
            document: document,
            env: canonicalEnv
        )
        #expect(resolved.host == "short.example.com")
        #expect(resolved.username == "canonicalized")
    }

    @Test("Match final runs without CanonicalizeHostname and overrides first pass")
    func matchFinalOverridesFirstPass() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host *
            User firstuser
            Port 2200
        Match final host target
            User finaluser
            Port 9999
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "target"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "finaluser")
        #expect(resolved.port == 9999)
    }

    @Test("Match canonical does not apply when CanonicalizeHostname is off")
    func matchCanonicalSkippedWhenOff() {
        let document = SSHConfigParser.parseDocumentContent("""
        Match canonical
            User wouldbecanonical
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "raw"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "")
    }

    @Test("Jump host resolves through ssh config")
    func jumpHostResolves() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host bastion
            HostName real-bastion.example.com
            User opsuser
            Port 2200
        """)
        var jump = SSHJumpHost()
        jump.host = "bastion"
        let resolved = SSHConfigResolver.resolve(jump, document: document, env: Self.stubEnv)
        #expect(resolved.host == "real-bastion.example.com")
        #expect(resolved.username == "opsuser")
        #expect(resolved.port == 2200)
    }

    @Test("Global directives apply before any Host stanza")
    func globalDirective() {
        let document = SSHConfigParser.parseDocumentContent("""
        User globaluser
        Host alias
            HostName 1.2.3.4
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "alias"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "globaluser")
    }
}
