//
//  SSHJumpChainTests.swift
//  TableProTests
//
//  A jump host may declare a jump host of its own. Measured with OpenSSH_10.3p1 on the config in
//  `followsNestedProxyJump`: ssh connects to `ay`, tunnels to `bee`, then reaches `target`.
//

import Foundation
import TableProPluginKit
@testable import TablePro
@testable import TableProSSHConfig
import Testing

struct SSHJumpChainTests {
    private static let env = ResolverEnvironment(
        runShell: { _ in true },
        canonicalize: { host, _ in host },
        currentLocalUser: { "tester" },
        localHostname: { "Mac" }
    )

    private func chain(_ content: String, from jumpHosts: [SSHJumpHost]) -> [ResolvedSSHTarget] {
        resolvedJumps(content, from: jumpHosts).map(\.target)
    }

    private func resolvedJumps(_ content: String, from jumpHosts: [SSHJumpHost]) -> [LibSSH2TunnelFactory.ResolvedJump] {
        LibSSH2TunnelFactory.resolveJumpChain(
            jumpHosts,
            fromForm: true,
            document: SSHConfigParser.parseDocumentContent(content),
            env: Self.env
        )
    }

    private func jump(_ host: String) -> SSHJumpHost {
        var jumpHost = SSHJumpHost()
        jumpHost.host = host
        return jumpHost
    }

    /// `ssh -v` on this config reports two proxy commands: `... -W [bee.example.com]:22 ay` then
    /// `... -W [10.0.0.9]:22 bee`. So the hop nearest the user comes first.
    @Test("A jump host's own ProxyJump is followed, outermost hop first")
    func followsNestedProxyJump() {
        let resolved = chain(
            """
            Host bee
                Hostname bee.example.com
                ProxyJump ay
            Host ay
                Hostname ay.example.com
            """,
            from: [jump("bee")]
        )
        #expect(resolved.map(\.host) == ["ay.example.com", "bee.example.com"])
    }

    @Test("A chain three deep keeps its order")
    func followsThreeLevels() {
        let resolved = chain(
            """
            Host cee
                Hostname cee.example.com
                ProxyJump bee
            Host bee
                Hostname bee.example.com
                ProxyJump ay
            Host ay
                Hostname ay.example.com
            """,
            from: [jump("cee")]
        )
        #expect(resolved.map(\.host) == ["ay.example.com", "bee.example.com", "cee.example.com"])
    }

    @Test("A hop with no ProxyJump of its own resolves to itself")
    func plainHopIsUnchanged() {
        let resolved = chain(
            """
            Host bastion
                Hostname bastion.example.com
                User opsuser
                Port 2200
            """,
            from: [jump("bastion")]
        )
        #expect(resolved.map(\.host) == ["bastion.example.com"])
        #expect(resolved.first?.username == "opsuser")
        #expect(resolved.first?.port == 2_200)
    }

    @Test("Several jump hosts each expand in place")
    func expandsEachHopInPlace() {
        let resolved = chain(
            """
            Host first
                Hostname first.example.com
                ProxyJump behind-first
            Host behind-first
                Hostname behind-first.example.com
            Host second
                Hostname second.example.com
            """,
            from: [jump("first"), jump("second")]
        )
        #expect(resolved.map(\.host) == [
            "behind-first.example.com",
            "first.example.com",
            "second.example.com",
        ])
    }

    @Test("In a list only the first hop's own ProxyJump is followed, as ssh -J a,b does")
    func followsOnlyTheFirstHopsProxyJump() {
        let resolved = chain(
            """
            Host first
                Hostname first.example.com
            Host second
                Hostname second.example.com
                ProxyJump behind-second
            Host behind-second
                Hostname behind-second.example.com
            """,
            from: [jump("first"), jump("second")]
        )
        #expect(resolved.map(\.host) == ["first.example.com", "second.example.com"])
    }

    @Test("Each hop keeps the form jump host it came from, so a hop ProxyJump adds cannot take its key")
    func hopsKeepTheirFormHost() {
        var keyed = jump("first")
        keyed.authMethod = .privateKey
        keyed.privateKeyPath = "~/.ssh/first_key"
        let resolved = resolvedJumps(
            """
            Host first
                Hostname first.example.com
                ProxyJump behind-first
            Host behind-first
                Hostname behind-first.example.com
            """,
            from: [keyed]
        )

        #expect(resolved.map(\.target.host) == ["behind-first.example.com", "first.example.com"])
        #expect(resolved[0].formHop == nil)
        #expect(resolved[1].formHop?.id == keyed.id)
        #expect(resolved[1].formHop?.authMethod == .privateKey)
    }

    /// A pair of hosts naming each other would otherwise recurse until the stack ran out.
    @Test("A ProxyJump cycle terminates")
    func cycleTerminates() {
        let resolved = chain(
            """
            Host ay
                Hostname ay.example.com
                ProxyJump bee
            Host bee
                Hostname bee.example.com
                ProxyJump ay
            """,
            from: [jump("ay")]
        )
        #expect(resolved.count <= 10)
        #expect(!resolved.isEmpty)
    }

    @Test("An empty jump list stays empty")
    func emptyListIsEmpty() {
        #expect(chain("Host anything\n    Hostname anything.example.com", from: []).isEmpty)
    }
}
