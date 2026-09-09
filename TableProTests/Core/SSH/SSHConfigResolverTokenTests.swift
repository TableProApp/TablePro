//
//  SSHConfigResolverTokenTests.swift
//  TableProTests
//
//  Resolution against ~/.ssh/config, checked case by case against what OpenSSH_10.3p1 reports for
//  the same file. Each expectation names the `ssh -G` output it was taken from.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SSH config resolver tokens")
struct SSHConfigResolverTokenTests {
    private static let env = ResolverEnvironment(
        runShell: { _ in true },
        canonicalize: { host, _ in host },
        currentLocalUser: { "tester" },
        localHostname: { "Mac" }
    )

    private func makeConfig(
        host: String,
        port: Int? = nil,
        username: String = "",
        privateKeyPath: String = "",
        jumpHosts: [SSHJumpHost] = []
    ) -> SSHConfiguration {
        SSHConfiguration(
            enabled: true,
            host: host,
            port: port,
            username: username,
            authMethod: .privateKey,
            privateKeyPath: privateKeyPath,
            agentSocketPath: "",
            jumpHosts: jumpHosts
        )
    }

    private func resolve(_ content: String, host: String, jumpHosts: [SSHJumpHost] = []) -> ResolvedSSHTarget {
        SSHConfigResolver.resolve(
            makeConfig(host: host, jumpHosts: jumpHosts),
            document: SSHConfigParser.parseDocumentContent(content),
            env: Self.env
        )
    }

    /// The reported bug. `ssh -F c -G db.example.com` printed `hostname db.example.com`; TablePro
    /// sent the two characters `%h` to getaddrinfo.
    @Test("Host *.* with Hostname %h keeps the host the connection named")
    func hostnamePassthrough() {
        let resolved = resolve(
            """
            Host *.*
                Hostname %h
            """,
            host: "db.example.com"
        )
        #expect(resolved.host == "db.example.com")
        #expect(resolved.expansionFailure == nil)
    }

    @Test("%h inside HostName is the original host")
    func hostnameTokenUsesOriginalHost() {
        let resolved = resolve(
            """
            Host short
                Hostname box.%h.example.com
            """,
            host: "short"
        )
        #expect(resolved.host == "box.short.example.com")
    }

    /// `Host t1 / Hostname a.example.com` then `Host t1 / Hostname zzz-%h` gave `a.example.com`,
    /// so the second never applies and `%h` cannot chain onto the first.
    @Test("HostName is first-wins and %h never chains")
    func hostnameFirstWins() {
        let resolved = resolve(
            """
            Host t1
                Hostname a.example.com
            Host t1
                Hostname zzz-%h
            """,
            host: "t1"
        )
        #expect(resolved.host == "a.example.com")
    }

    @Test("A token HostName does not accept is reported instead of dialled")
    func hostnameRejectsOutOfScopeToken() {
        let resolved = resolve(
            """
            Host t1
                Hostname %d.example.com
            """,
            host: "t1"
        )
        #expect(resolved.expansionFailure == .unsupportedToken(keyword: "HostName", token: "%d"))
    }

    @Test("An empty HostName is not a value")
    func emptyHostNameIsIgnored() {
        let resolved = resolve(
            """
            Host t1
                HostName
            """,
            host: "t1"
        )
        #expect(resolved.host == "t1")
    }

    /// `ssh -G` gave port 22 and the local user: a `Host` pattern is matched against the host the
    /// command line named, never against a `HostName` an earlier block substituted.
    @Test("Host patterns match the host the connection named")
    func hostPatternsIgnoreSubstitution() {
        let resolved = resolve(
            """
            Host jump
                HostName bastion.internal.example.com
            Host *.internal.example.com
                User internaluser
                Port 2200
            """,
            host: "jump"
        )
        #expect(resolved.host == "bastion.internal.example.com")
        #expect(resolved.port == 22)
        #expect(resolved.username.isEmpty)
    }

    /// The other half of the same rule: `Match host` does see the substitution, and folds case.
    @Test("Match host sees the substituted hostname and ignores case")
    func matchHostSeesSubstitution() {
        let resolved = resolve(
            """
            Host alias
                HostName real.example.com
            Match host REAL.example.com
                User matched
            """,
            host: "alias"
        )
        #expect(resolved.username == "matched")
    }

    @Test("Match host still resolves when HostName carries a token")
    func matchHostSeesExpandedHostname() {
        let resolved = resolve(
            """
            Host db.example.com
                Hostname %h
            Match host db.example.com
                User matched
            """,
            host: "db.example.com"
        )
        #expect(resolved.username == "matched")
    }

    /// `Match !host excluded` gave port 22 for `excluded` and 6666 for anything else. Dropping the
    /// negation made the block match every host, the excluded one included.
    @Test("A negated Match criterion excludes the host it names")
    func negatedMatchExcludes() {
        let content = """
        Match !host excluded
            Port 6666
        """
        #expect(resolve(content, host: "excluded").port == 22)
        #expect(resolve(content, host: "included").port == 6_666)
    }

    @Test("A negated Match host list excludes every entry")
    func negatedMatchList() {
        let content = """
        Match !host a,b
            Port 6666
        """
        #expect(resolve(content, host: "a").port == 22)
        #expect(resolve(content, host: "b").port == 22)
        #expect(resolve(content, host: "c").port == 6_666)
    }

    /// `ssh -G target` gave `firstuser` and 2200: first-wins holds across both passes, so a
    /// `Match final` block supplies a default and does not override an earlier value.
    @Test("Match final does not override a value an earlier block set")
    func matchFinalDoesNotOverride() {
        let resolved = resolve(
            """
            Host *
                User firstuser
                Port 2200
            Match final host target
                User finaluser
                Port 9999
            """,
            host: "target"
        )
        #expect(resolved.username == "firstuser")
        #expect(resolved.port == 2_200)
    }

    @Test("Match final still supplies a value nothing set")
    func matchFinalSuppliesDefault() {
        let resolved = resolve(
            """
            Host target
                Port 2200
            Match final host target
                User finaluser
            """,
            host: "target"
        )
        #expect(resolved.username == "finaluser")
        #expect(resolved.port == 2_200)
    }

    /// `ssh -G s` listed both keys. Replacing the list dropped every per-host key the moment a
    /// `Match final` block added a shared one.
    @Test("IdentityFile accumulates across both passes")
    func identityFilesAccumulate() {
        let resolved = resolve(
            """
            Host s
                IdentityFile /tmp/first_key
            Match final host s
                IdentityFile /tmp/final_key
            """,
            host: "s"
        )
        #expect(resolved.identityFiles == ["/tmp/first_key", "/tmp/final_key"])
    }

    @Test("IdentityFile expands the standard tokens and the tilde")
    func identityFileTokens() {
        let resolved = resolve(
            """
            Host tok
                Hostname 127.0.0.1
                Port 2222
                User bob
                IdentityFile ~/.ssh/id_%r_%p_%n_%h_%u.pem
            """,
            host: "tok"
        )
        #expect(resolved.identityFiles == ["\(NSHomeDirectory())/.ssh/id_bob_2222_tok_127.0.0.1_tester.pem"])
    }

    @Test("IdentityAgent expands tokens and the tilde")
    func identityAgentTokens() {
        let resolved = resolve(
            """
            Host tok
                Hostname 10.0.0.5
                IdentityAgent ~/.agent_%h.sock
            """,
            host: "tok"
        )
        #expect(resolved.agentSocketPath == "\(NSHomeDirectory())/.agent_10.0.0.5.sock")
        #expect(resolved.agentSocketOrigin == .identityAgentDirective)
    }

    /// `ssh -v` reported `exec ssh -l bob … jump-127.0.0.1-tok-2222`, so the tokens bind to the
    /// final target's resolved values and `%n` to the original host.
    @Test("ProxyJump expands against the final target")
    func proxyJumpTokens() {
        let resolved = resolve(
            """
            Host tok
                Hostname 127.0.0.1
                Port 2222
                User bob
                ProxyJump %r@jump-%h-%n-%p
            """,
            host: "tok"
        )
        #expect(resolved.proxyJump.count == 1)
        #expect(resolved.proxyJump.first?.username == "bob")
        #expect(resolved.proxyJump.first?.host == "jump-127.0.0.1-tok-2222")
    }

    /// ssh splits the hops before expanding them. Expanding first let a username carrying a comma
    /// turn one configured hop into two and route the session through a host nothing named.
    @Test("A comma inside an expanded token does not add a jump host")
    func proxyJumpCommaDoesNotSplitIntoAnExtraHop() {
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "tok", username: "bob,evil.example.net"),
            document: SSHConfigParser.parseDocumentContent(
                """
                Host tok
                    Hostname 127.0.0.1
                    ProxyJump %r@gw.example.com
                """
            ),
            env: Self.env
        )
        #expect(resolved.proxyJump.count == 1)
        #expect(resolved.proxyJump.first?.host == "gw.example.com")
        #expect(resolved.proxyJump.first?.username == "bob,evil.example.net")
    }

    @Test("A ProxyJump naming several hops still resolves each of them")
    func proxyJumpKeepsEveryConfiguredHop() {
        let resolved = resolve(
            """
            Host tok
                Hostname 10.0.0.9
                ProxyJump first.example.com,ops@second.example.com:2200
            """,
            host: "tok"
        )
        #expect(resolved.proxyJump.map(\.host) == ["first.example.com", "second.example.com"])
        #expect(resolved.proxyJump.last?.port == 2_200)
        #expect(resolved.proxyJump.last?.username == "ops")
    }

    /// A criterion that could not be evaluated fails the block whichever way it was written.
    /// Reporting it as "did not hold" let a negated one be satisfied by its own failure.
    @Test("A Match exec that cannot be expanded fails the block, negated or not")
    func unevaluableMatchExecFailsClosed() {
        for line in ["Match exec \"probe %f\"", "Match !exec \"probe %f\""] {
            let resolved = resolve(
                """
                \(line)
                    Port 6789
                """,
                host: "anything"
            )
            #expect(resolved.port == 22, "\(line) should not have applied")
        }
    }

    @Test("A token ProxyJump does not accept is reported")
    func proxyJumpRejectsOutOfScopeToken() {
        let resolved = resolve(
            """
            Host t1
                ProxyJump box-%C
            """,
            host: "t1"
        )
        #expect(resolved.expansionFailure == .unsupportedToken(keyword: "ProxyJump", token: "%C"))
    }

    /// `%j` is the jump host in effect. Jump hosts typed into the form override the config's
    /// `ProxyJump` the way `ssh -J` does, so `%C` has to be built from those instead.
    @Test("%C follows the form's jump hosts when they override the config")
    func connectionHashFollowsFormJumpHosts() {
        var formJump = SSHJumpHost()
        formJump.host = "formbox"
        formJump.username = "ops"

        let content = """
        Host tok
            Hostname 127.0.0.1
            Port 2222
            User bob
            ProxyJump jbox
            IdentityFile /keys/%C.pem
        """
        let withForm = resolve(content, host: "tok", jumpHosts: [formJump])
        let withConfig = resolve(content, host: "tok")

        #expect(withForm.identityFiles != withConfig.identityFiles)
        #expect(withConfig.identityFiles == ["/keys/6a6931654bbdcabda8a3566634df2bbb00e56137.pem"])
    }

    /// `Match exec` takes the full token set. Passing no port left `%p` in the command, so a probe
    /// like `nc -z %h %p` ran against a literal token, failed, and dropped whatever the block set.
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

    @Test("Match exec receives the resolved port and user")
    func matchExecReceivesPortAndUser() {
        let recorder = CommandRecorder()
        let recordingEnv = ResolverEnvironment(
            runShell: { command in
                recorder.record(command)
                return true
            },
            canonicalize: { host, _ in host },
            currentLocalUser: { "tester" },
            localHostname: { "Mac" }
        )
        _ = SSHConfigResolver.resolve(
            makeConfig(host: "t"),
            document: SSHConfigParser.parseDocumentContent(
                """
                Host t
                    Port 4242
                    User carol
                Match exec "probe %h %p %r"
                    Compression yes
                """
            ),
            env: recordingEnv
        )
        #expect(recorder.recorded == ["probe t 4242 carol"])
    }

    /// ssh hands the command to the shell with its dollar expressions intact, so
    /// `test x${MODE:-dev} = xdev` is the shell's to resolve. Expanding it here looked up a
    /// variable named `MODE:-dev`, failed, and dropped the block.
    @Test("Match exec keeps ${...} for the shell")
    func matchExecLeavesEnvironmentToTheShell() {
        let recorder = CommandRecorder()
        let recordingEnv = ResolverEnvironment(
            runShell: { command in
                recorder.record(command)
                return true
            },
            canonicalize: { host, _ in host },
            currentLocalUser: { "tester" },
            localHostname: { "Mac" }
        )
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "h"),
            document: SSHConfigParser.parseDocumentContent(
                """
                Match exec "test x${TABLEPRO_MODE:-dev} = xdev"
                    Port 6001
                """
            ),
            env: recordingEnv
        )
        #expect(recorder.recorded == ["test x${TABLEPRO_MODE:-dev} = xdev"])
        #expect(resolved.expansionFailure == nil)
        #expect(resolved.port == 6_001)
    }

    /// `ssh -G` on the same file matched the block, so `%p` is the effective port even when
    /// nothing set one. Leaving it empty made `test x%p = x22` fail and drop the directives.
    @Test("Match exec sees the effective port and user")
    func matchExecSeesEffectiveValues() {
        let recorder = CommandRecorder()
        let recordingEnv = ResolverEnvironment(
            runShell: { command in
                recorder.record(command)
                return true
            },
            canonicalize: { host, _ in host },
            currentLocalUser: { "tester" },
            localHostname: { "Mac" }
        )
        _ = SSHConfigResolver.resolve(
            makeConfig(host: "h", port: 2_345, username: "formuser"),
            document: SSHConfigParser.parseDocumentContent(
                """
                Match exec "probe %p %r"
                    Compression yes
                """
            ),
            env: recordingEnv
        )
        #expect(recorder.recorded == ["probe 2345 formuser"])
    }

    @Test("Match exec defaults the port to 22 when nothing sets one")
    func matchExecDefaultsPort() {
        let recorder = CommandRecorder()
        let recordingEnv = ResolverEnvironment(
            runShell: { command in
                recorder.record(command)
                return true
            },
            canonicalize: { host, _ in host },
            currentLocalUser: { "tester" },
            localHostname: { "Mac" }
        )
        _ = SSHConfigResolver.resolve(
            makeConfig(host: "h"),
            document: SSHConfigParser.parseDocumentContent(
                """
                Match exec "probe %p"
                    Compression yes
                """
            ),
            env: recordingEnv
        )
        #expect(recorder.recorded == ["probe 22"])
    }

    /// `ssh -G h` on `Match !final` applies the block, because `final` is false on the pass that
    /// runs. Treating the negation as a second-pass criterion meant it could never apply.
    @Test("Match !final applies on the ordinary pass")
    func negatedFinalAppliesOnTheFirstPass() {
        let resolved = resolve(
            """
            Match !final
                User notfinal
            """,
            host: "h"
        )
        #expect(resolved.username == "notfinal")
    }

    /// With several hops ssh names the last one: `ProxyJump first,second` gave
    /// `/keys/j_second.example.com.pem`.
    @Test("%j is the hop nearest the target")
    func jumpHostTokenIsTheLastHop() {
        let resolved = resolve(
            """
            Host tok
                Hostname 127.0.0.1
                ProxyJump first.example.com,second.example.com
                IdentityFile /keys/j_%j.pem
            """,
            host: "tok"
        )
        #expect(resolved.identityFiles == ["/keys/j_second.example.com.pem"])
    }

    @Test("HostKeyAlias supplies %k")
    func hostKeyAliasSuppliesTheAliasToken() {
        let resolved = resolve(
            """
            Host tok
                Hostname 10.0.0.4
                HostKeyAlias key-name
                IdentityAgent /tmp/%k.sock
            """,
            host: "tok"
        )
        #expect(resolved.agentSocketPath == "/tmp/key-name.sock")
    }

    @Test("A form identity file still wins over the config")
    func formIdentityFileWins() {
        let resolved = SSHConfigResolver.resolve(
            makeConfig(host: "tok", privateKeyPath: "/form/key.pem"),
            document: SSHConfigParser.parseDocumentContent(
                """
                Host tok
                    IdentityFile /keys/%h.pem
                """
            ),
            env: Self.env
        )
        #expect(resolved.identityFiles == ["/form/key.pem"])
    }
}
