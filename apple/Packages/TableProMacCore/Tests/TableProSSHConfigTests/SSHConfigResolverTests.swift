//
//  SSHConfigResolverTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TableProSSHConfig

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
        #expect(resolved.port == 2_200)
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
            makeConfig(host: "alias", port: 9_999),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.port == 9_999)
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
        #expect(resolved.port == 2_200)
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
        #expect(resolved.port == 2_200)
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
        #expect(resolved.proxyJump[0].port == 2_200)
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

    @Test("ProxyJump none turns the jump off, even where a later Host * names one")
    func proxyJumpNoneDisables() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host bastion
            HostName b.example
            ProxyJump none
        Host *
            ProxyJump bastion
        """)
        let bastion = SSHConfigResolver.resolve(makeConfig(host: "bastion"), document: document, env: Self.stubEnv)
        let target = SSHConfigResolver.resolve(makeConfig(host: "db"), document: document, env: Self.stubEnv)

        #expect(bastion.proxyJump.isEmpty)
        #expect(target.proxyJump.map(\.host) == ["bastion"])
    }

    @Test("A ProxyJump hop written as an ssh URI keeps its user, host and port")
    func proxyJumpSSHURI() throws {
        let document = SSHConfigParser.parseDocumentContent("""
        Host db
            ProxyJump ssh://ops%40corp@b.example:2222
        """)
        let resolved = SSHConfigResolver.resolve(makeConfig(host: "db"), document: document, env: Self.stubEnv)
        let hop = try #require(resolved.proxyJump.first)

        #expect(hop.username == "ops@corp")
        #expect(hop.host == "b.example")
        #expect(hop.port == 2_222)
    }

    @Test("IdentityAgent none turns the agent off instead of naming a socket")
    func identityAgentNone() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host db
            IdentityAgent none
        """)
        let resolved = SSHConfigResolver.resolve(makeConfig(host: "db"), document: document, env: Self.stubEnv)

        #expect(resolved.agentDisabled)
        #expect(resolved.agentSocketPath.isEmpty)
    }

    @Test("IdentityAgent SSH_AUTH_SOCK reads the socket from the environment")
    func identityAgentEnvironment() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host db
            IdentityAgent SSH_AUTH_SOCK
        """)
        let resolved = SSHConfigResolver.resolve(makeConfig(host: "db"), document: document, env: Self.stubEnv)

        #expect(!resolved.agentDisabled)
        #expect(resolved.agentSocketPath.isEmpty)
        #expect(resolved.agentSocketOrigin == .environment)
    }

    @Test("CanonicalizeHostname yes leaves a host reached through a jump alone, and always does not")
    func canonicalizeSkipsProxiedHostsUnlessAlways() {
        let env = ResolverEnvironment(
            runShell: { _ in true },
            canonicalize: { host, _ in host + ".corp.example" },
            currentLocalUser: { "tester" }
        )
        func resolvedHost(mode: String) -> String {
            let document = SSHConfigParser.parseDocumentContent("""
            Host db
                CanonicalizeHostname \(mode)
                CanonicalDomains corp.example
                ProxyJump bastion
            """)
            return SSHConfigResolver.resolve(makeConfig(host: "db"), document: document, env: env).host
        }

        #expect(resolvedHost(mode: "yes") == "db")
        #expect(resolvedHost(mode: "always") == "db.corp.example")
    }

    private func user(for content: String, addresses: [String] = []) -> String {
        let env = ResolverEnvironment(
            runShell: { _ in true },
            canonicalize: { host, _ in host },
            currentLocalUser: { "tester" },
            localAddresses: { addresses }
        )
        let document = SSHConfigParser.parseDocumentContent(content)
        return SSHConfigResolver.resolve(makeConfig(host: "db"), document: document, env: env).username
    }

    @Test("Match localnetwork applies only on a network this Mac is on")
    func matchLocalNetwork() {
        let config = """
        Match host db localnetwork 10.0.0.0/8,192.168.1.0/24
            User office
        Host db
            User remote
        """
        #expect(user(for: config, addresses: ["127.0.0.1", "10.1.2.3"]) == "office")
        #expect(user(for: config, addresses: ["fe80::1%en0", "172.16.0.4"]) == "remote")
    }

    @Test("Match tagged reads a Tag set earlier; a tunnel has no command and session type none")
    func matchTaggedCommandAndSessionType() {
        #expect(user(for: "Match tagged prod\n    User tagged\nHost db\n    User plain") == "plain")
        #expect(user(for: "Host db\n    Tag prod\nMatch tagged prod\n    User tagged") == "tagged")
        #expect(user(for: "Match tagged *\n    User any-tag\nMatch !tagged *\n    User untagged") == "untagged")
        #expect(user(for: "Match sessiontype none\n    User tunnel") == "tunnel")
        #expect(user(for: "Match command *\n    User any\nMatch command ?*\n    User some") == "any")
        #expect(user(for: "Match version OpenSSH_*\n    User openssh\nHost db\n    User other") == "other")
    }

    @Test("A Match criterion TablePro does not know keeps its block from applying either way")
    func unknownMatchCriterionNeverApplies() {
        #expect(user(for: "Match bogus x\n    User a\nMatch !bogus x\n    User b\nHost db\n    User c") == "c")
    }

    @Test("A CIDR network contains the addresses under its prefix only")
    func cidrContainment() {
        #expect(SSHLocalNetwork.contains(address: "10.1.2.3", cidr: "10.0.0.0/8"))
        #expect(!SSHLocalNetwork.contains(address: "11.1.2.3", cidr: "10.0.0.0/8"))
        #expect(SSHLocalNetwork.contains(address: "2001:db8::5", cidr: "2001:db8::/32"))
        #expect(!SSHLocalNetwork.contains(address: "10.1.2.3", cidr: "2001:db8::/32"))
        #expect(SSHLocalNetwork.contains(address: "192.168.1.9", cidr: "192.168.1.9"))
        #expect(!SSHLocalNetwork.contains(address: "192.168.1.9", cidr: "192.168.1.0/33"))
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

    /// This used to assert the opposite. ssh keeps the first value it obtained for a keyword and
    /// that holds across both passes: `ssh -G target` on this exact file reports `firstuser` and
    /// 2200, so a `Match final` block supplies a default rather than overriding an earlier value.
    @Test("Match final runs without CanonicalizeHostname and does not override the first pass")
    func matchFinalDoesNotOverrideFirstPass() {
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
        #expect(resolved.username == "firstuser")
        #expect(resolved.port == 2_200)
    }

    @Test("Match final still supplies a value no earlier block set")
    func matchFinalSuppliesUnsetValue() {
        let document = SSHConfigParser.parseDocumentContent("""
        Host target
            Port 2200
        Match final host target
            User finaluser
        """)
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "target"),
            document: document,
            env: Self.stubEnv
        )
        #expect(resolved.username == "finaluser")
        #expect(resolved.port == 2_200)
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
        #expect(resolved.port == 2_200)
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
