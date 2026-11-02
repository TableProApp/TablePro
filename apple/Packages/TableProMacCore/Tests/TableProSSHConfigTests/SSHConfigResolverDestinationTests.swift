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
        port: Int? = nil,
        username: String = "",
        document: SSHConfigDocument = Self.document
    ) -> (target: ResolvedSSHTarget, commands: [String]) {
        let recorder = CommandRecorder()
        let target = SSHConfigResolver.resolve(
            SSHConfiguration(enabled: true, host: host, port: port, username: username, authMethod: .privateKey),
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
        "#corp.example",
        "db*.internal.example",
        "",
        "db\u{37E}id.internal.example",
        "db\u{1FEF}id\u{1FEF}.internal.example",
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
        "first last",
        "bob,evil.example.net",
        "deploy #",
        "deploy\u{1FEF}id\u{1FEF}",
    ])
    func hostileUserIsNotExpandedIntoACommand(username: String) {
        let (target, commands) = resolve(host: "db.example.com", username: username)
        #expect(commands.isEmpty)
        #expect(target.expansionFailure == .invalidDestination(.user(username)))
        #expect(target.identityFiles.isEmpty)
    }

    @Test("A user starting with a backslash still connects when no Match exec substitutes it")
    func leadingBackslashUserResolvesWhenNotSubstituted() {
        let document = SSHConfigParser.parseDocumentContent("""
            Match exec "probe %h %%r"
                Port 2222
            """)
        let username = "\\-oProxyCommand=printf"
        let (target, commands) = resolve(host: "db.example.com", username: username, document: document)
        #expect(commands == ["probe db.example.com %r"])
        #expect(target.expansionFailure == nil)
        #expect(target.port == 2_222)
    }

    @Test("A port outside 1 to 65535 stops resolution before any Match exec runs", arguments: [0, -1, 65_536])
    func outOfRangePortIsRefused(port: Int) {
        let (target, commands) = resolve(host: "db1.internal.example", port: port, username: "deploy")
        #expect(commands.isEmpty)
        #expect(target.expansionFailure == .invalidDestination(.port(port)))
        #expect(target.identityFiles.isEmpty)
    }

    @Test("A config Port outside 1 to 65535 never reaches the Match exec shell as %p", arguments: ["-1", "0", "70000"])
    func outOfRangeConfigPortIsNotExpanded(port: String) {
        let document = SSHConfigParser.parseDocumentContent("""
            Host db
                Port \(port)
            Match exec "nc -z %h %p"
                User deploy
            """)
        let (target, commands) = resolve(host: "db", document: document)
        #expect(commands.isEmpty)
        #expect(target.expansionFailure == .invalidDestination(.port(Int(port) ?? 0)))
    }

    @Test("A config Port outside 1 to 65535 is refused even when no Match exec uses it")
    func outOfRangeConfigPortIsRefused() {
        let document = SSHConfigParser.parseDocumentContent("""
            Host db
                Port 70000
            """)
        #expect(resolve(host: "db", document: document).target.expansionFailure == .invalidDestination(.port(70_000)))
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

    // Process hands U+1FEF over as a backtick and U+037E as `;`. On the old rules both ran the
    // payload and matched the block (measured).
    @Test("A user that decomposes into a backtick runs nothing through the real Match exec")
    func decomposedUserRunsNothing() throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("ran")
        let user = "deploy\u{1FEF}touch \(marker.path)\u{1FEF}"

        let target = SSHConfigResolver.resolve(
            SSHConfiguration(enabled: true, host: "db.example.com", username: user, authMethod: .privateKey),
            document: SSHConfigParser.parseDocumentContent("""
                Match exec "test %r = deploy"
                    Port 2222
                """),
            env: Self.liveEnvironment
        )

        #expect(target.expansionFailure == .invalidDestination(.user(user)))
        #expect(target.port == 22)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("A host that decomposes into a semicolon runs nothing through the real Match exec")
    func decomposedHostRunsNothing() throws {
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("ran")
        let payload = folder.appendingPathComponent("payload")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: payload, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.path)
        let host = "db\u{37E}\(payload.path)"

        let target = SSHConfigResolver.resolve(
            SSHConfiguration(enabled: true, host: host, username: "deploy", authMethod: .privateKey),
            document: SSHConfigParser.parseDocumentContent("""
                Match exec "test %h = db"
                    Port 2222
                """),
            env: Self.liveEnvironment
        )

        #expect(target.expansionFailure == .invalidDestination(.host(host)))
        #expect(target.port == 22)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private static let liveEnvironment = ResolverEnvironment(
        runShell: { SSHMatchExecutor.evaluate(command: $0) },
        canonicalize: { host, _ in host },
        currentLocalUser: { "tester" },
        localHostname: { "Mac" }
    )

    private static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("match-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
