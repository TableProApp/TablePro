//
//  MySQLDumpPlaintextPasswordTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

// The tool behavior these rules rest on is measured by scripts/probes/check-mysql-dump-plaintext-password.sh.
struct MySQLDumpPlaintextPasswordTests {
    private func connection(_ mode: SSLMode) -> DatabaseConnection {
        var ssl = SSLConfiguration()
        ssl.mode = mode
        return DatabaseConnection(
            name: "Test",
            host: "db.example.com",
            port: 3_306,
            database: "sales",
            username: "alice",
            type: .mysql,
            sshConfig: SSHConfiguration(),
            sslConfig: ssl
        )
    }

    private func command(
        _ connection: DatabaseConnection,
        kind: NativeDumpKind = .backup,
        flavor: NativeDumpToolFlavor = .mariadb,
        toolPath: String = "/nonexistent/bin/mariadb-dump",
        serverOffersTLS: Bool? = nil
    ) throws -> NativeDumpCommand {
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        return try NativeDumpService.buildCommand(
            kind: kind,
            tool: tool,
            resolved: NativeDumpResolvedTool(name: "mariadb-dump", path: toolPath, flavor: flavor),
            request: NativeDumpDescriptor.Request(
                connection: connection,
                database: "sales",
                fileURL: URL(fileURLWithPath: "/tmp/out.sql"),
                password: "s3cret",
                serverOffersTLS: serverOffersTLS
            )
        )
    }

    private func discard(_ built: NativeDumpCommand) {
        if let url = built.clientPluginFolder?.url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func pluginDirectoryArgument(_ built: NativeDumpCommand) -> String? {
        built.arguments.first { $0.hasPrefix("--plugin-dir=") }
    }

    @Test("Disabled hides the plain-text plugins from MariaDB's tools, in both directions", arguments: [
        NativeDumpKind.backup, .restore
    ])
    func disabledHidesPlaintextPlugins(kind: NativeDumpKind) throws {
        let built = try command(connection(.disabled), kind: kind)
        defer { discard(built) }
        let folder = try #require(built.clientPluginFolder)
        #expect(pluginDirectoryArgument(built) == "--plugin-dir=\(folder.url.path)")
        #expect(FileManager.default.fileExists(atPath: folder.url.path))
        #expect(built.arguments.contains("--skip-ssl"))
        let terminator = try #require(built.arguments.firstIndex(of: "--"))
        let flag = try #require(built.arguments.firstIndex { $0.hasPrefix("--plugin-dir=") })
        #expect(flag < terminator)
    }

    @Test("Preferred dials MariaDB's tools in plaintext with the plugins hidden when the server offers no TLS")
    func preferredWithoutTLSOffer() throws {
        let built = try command(connection(.preferred), serverOffersTLS: false)
        defer { discard(built) }
        #expect(built.arguments.contains("--skip-ssl"))
        #expect(!built.arguments.contains("--ssl"))
        #expect(pluginDirectoryArgument(built) != nil)
    }

    @Test("Preferred keeps TLS and every plugin when the server offers TLS")
    func preferredWithTLSOffer() throws {
        var preferred = connection(.preferred)
        preferred.sslConfig.clientCertificatePath = "/certs/client.pem"
        let built = try command(preferred, serverOffersTLS: true)
        #expect(built.arguments.contains("--ssl"))
        #expect(built.arguments.contains("--skip-ssl-verify-server-cert"))
        #expect(built.arguments.contains("--ssl-cert=/certs/client.pem"))
        #expect(built.clientPluginFolder == nil)
        #expect(pluginDirectoryArgument(built) == nil)
    }

    // --ssl-cert implies --ssl on MariaDB, which would bring back the fallback that sends the password as typed.
    @Test("Preferred in plaintext sends no certificate that would turn TLS back on")
    func preferredWithoutTLSOfferDropsCertificates() throws {
        var preferred = connection(.preferred)
        preferred.sslConfig.clientCertificatePath = "/certs/client.pem"
        preferred.sslConfig.clientKeyPath = "/certs/client.key"
        let built = try command(preferred, serverOffersTLS: false)
        defer { discard(built) }
        #expect(!built.arguments.contains { $0.hasPrefix("--ssl") })
    }

    @Test(
        "Modes that require TLS keep every plugin",
        arguments: [TableProPluginKit.SSLMode.required, .verifyCa, .verifyIdentity]
    )
    func requiredKeepsPlugins(mode: TableProPluginKit.SSLMode) throws {
        let built = try command(connection(mode))
        #expect(built.clientPluginFolder == nil)
        #expect(pluginDirectoryArgument(built) == nil)
    }

    @Test("A token sign-in is raised to Required and keeps the plain-text plugin it needs")
    func tokenKeepsPlugins() throws {
        var iam = connection(.disabled)
        iam.additionalFields["awsAuth"] = "gcpServiceAccount"
        let built = try command(iam)
        #expect(built.arguments.contains("--ssl-verify-server-cert"))
        #expect(built.clientPluginFolder == nil)
    }

    @Test("A unix socket and a tunnel that secures the hop keep every plugin")
    func secureTransportsKeepPlugins() throws {
        var socket = connection(.disabled)
        socket.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/mysql.sock"
        #expect(try command(socket).clientPluginFolder == nil)
        #expect(!MySQLClientArguments.needsServerTLSAnswer(socket, flavor: .mariadb))

        var proxied = connection(.preferred)
        proxied.additionalFields[DatabaseConnection.tunnelSecuresTransportKey] = "true"
        #expect(try command(proxied).clientPluginFolder == nil)
        #expect(!MySQLClientArguments.needsServerTLSAnswer(proxied, flavor: .mariadb))
    }

    @Test("MySQL's own tools are left as they are")
    func mysqlToolsUntouched() throws {
        for mode in [SSLMode.disabled, .preferred] {
            let built = try command(connection(mode), flavor: .mysql, serverOffersTLS: false)
            #expect(built.clientPluginFolder == nil)
            #expect(pluginDirectoryArgument(built) == nil)
            #expect(!MySQLClientArguments.needsServerTLSAnswer(connection(mode), flavor: .mysql))
        }
        #expect(try command(connection(.preferred), flavor: .mysql).arguments.contains("--ssl-mode=PREFERRED"))
    }

    private func answering(_ cipher: String?) -> NativeDumpDescriptor.SessionQuery {
        { sql in
            guard sql == "SHOW SESSION STATUS LIKE 'Ssl_cipher'", let cipher else { throw DatabaseError.notConnected }
            return [["Ssl_cipher", cipher]]
        }
    }

    private func request(_ mode: SSLMode) -> NativeDumpDescriptor.Request {
        NativeDumpDescriptor.Request(
            connection: connection(mode),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/out.sql"),
            password: nil
        )
    }

    @Test("Only a MariaDB tool on Preferred asks the session whether the server offers TLS")
    func sessionIsAskedOnlyForPreferred() async throws {
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        let client = try fakeClient(sendsPassword: false)
        defer { try? FileManager.default.removeItem(at: client.deletingLastPathComponent()) }
        let unanswered: NativeDumpDescriptor.SessionQuery = { _ in
            Issue.record("the session should not be asked")
            return []
        }
        for (mode, flavor) in [(SSLMode.disabled, NativeDumpToolFlavor.mariadb), (.required, .mariadb), (.preferred, .mysql)] {
            let resolved = NativeDumpResolvedTool(name: "mariadb-dump", path: client.path, flavor: flavor)
            let prepared = try await tool.prepare(request(mode), resolved, unanswered)
            #expect(prepared.serverOffersTLS == nil, "\(mode.rawValue) \(flavor)")
        }
    }

    // The app's own session on Preferred takes TLS whenever the server offers it.
    @Test("Preferred takes the session's cipher as the server's answer")
    func preferredReadsTheSessionCipher() async throws {
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        let client = try fakeClient(sendsPassword: false)
        defer { try? FileManager.default.removeItem(at: client.deletingLastPathComponent()) }
        let resolved = NativeDumpResolvedTool(name: "mariadb-dump", path: client.path, flavor: .mariadb)

        let encrypted = try await tool.prepare(request(.preferred), resolved, answering("TLS_AES_256_GCM_SHA384"))
        #expect(encrypted.serverOffersTLS == true)
        let plain = try await tool.prepare(request(.preferred), resolved, answering(""))
        #expect(plain.serverOffersTLS == false)
    }

    // Guessing no TLS would dump in plaintext from a server that has it; guessing TLS brings back the fallback.
    @Test("A session that cannot answer fails the run instead of a guess")
    func unansweredSessionFailsTheRun() async throws {
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        let resolved = NativeDumpResolvedTool(name: "mariadb-dump", path: "/t", flavor: .mariadb)
        await #expect(throws: NativeDumpError.self) {
            try await tool.prepare(request(.preferred), resolved, answering(nil))
        }
        await #expect(throws: NativeDumpError.self) {
            try await tool.prepare(request(.preferred), resolved) { _ in [] }
        }
    }

    @Test("The plugin folder is found beside a Homebrew tool, through its link")
    func pluginDirectoryBesideTheTool() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keg = root.appendingPathComponent("Cellar/mariadb/13.0.2")
        let plugins = keg.appendingPathComponent("lib/plugin")
        try FileManager.default.createDirectory(at: keg.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let binary = keg.appendingPathComponent("bin/mariadb-dump")
        #expect(FileManager.default.createFile(atPath: binary.path, contents: nil))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("bin/mariadb-dump")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)

        let found = try #require(MariaDBClientPluginFolder.pluginDirectory(forTool: link.path))
        #expect(found.resolvingSymlinksInPath().path == plugins.resolvingSymlinksInPath().path)
        #expect(MariaDBClientPluginFolder.pluginDirectory(forTool: root.appendingPathComponent("nowhere/x").path) == nil)
    }

    @Test("MacPorts keeps the plugin folder beside bin")
    func pluginDirectoryInMacPortsLayout() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let version = root.appendingPathComponent("lib/mariadb-11.4")
        try FileManager.default.createDirectory(at: version.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: version.appendingPathComponent("plugin"), withIntermediateDirectories: true)
        let binary = version.appendingPathComponent("bin/mariadb-dump")
        #expect(FileManager.default.createFile(atPath: binary.path, contents: nil))

        let found = try #require(MariaDBClientPluginFolder.pluginDirectory(forTool: binary.path))
        #expect(found.resolvingSymlinksInPath().path == version.appendingPathComponent("plugin").resolvingSymlinksInPath().path)
    }

    @Test("The private folder links only the plugins that never send the password as typed")
    func privateFolderLinksOnlyAllowedPlugins() throws {
        let source = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let shipped = [
            "caching_sha2_password.so", "client_ed25519.so", "mysql_clear_password.so", "dialog.so", "parsec.so",
            "qa_auth_client.so", "qa_auth_interface.so", "auth_test_plugin.so", "zstd.so", "ha_archive.so"
        ]
        for name in shipped {
            #expect(FileManager.default.createFile(atPath: source.appendingPathComponent(name).path, contents: Data(name.utf8)))
        }

        let folder = try MariaDBClientPluginFolder.make(from: source)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let linked = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        #expect(linked == ["caching_sha2_password.so", "client_ed25519.so", "parsec.so", "zstd.so"])
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: folder.url.appendingPathComponent("parsec.so").path
        )
        #expect(destination == source.appendingPathComponent("parsec.so").path)

        let empty = try MariaDBClientPluginFolder.make(from: nil)
        defer { try? FileManager.default.removeItem(at: empty.url) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: empty.url.path).isEmpty)
    }

    @Test("A plugin left out of the folder reads as the plain-text refusal, an allowed one keeps the tool's words")
    func refusalFollowsTheAllowList() throws {
        let folder = MariaDBClientPluginFolder(url: URL(fileURLWithPath: "/nonexistent/folder"))
        let refusal = MySQLClientArguments.plaintextPasswordRefusal
        let dump = #"mariadb-dump: Got error: 2059: "Plugin dialog could not be loaded: dlopen(/x/dialog.so, 0x0002)" when trying to connect"#
        #expect(folder.refusal(in: dump) == refusal)
        #expect(folder.refusal(in: "ERROR 2059 (HY000): Plugin mysql_clear_password could not be loaded: dlopen(/x)") == refusal)
        #expect(folder.refusal(in: "ERROR 2059 (HY000): Plugin qa_auth_client could not be loaded: dlopen(/x)") == refusal)
        #expect(folder.refusal(in: "ERROR 2059 (HY000): Plugin caching_sha2_password could not be loaded: dlopen(/x)") == nil)
        #expect(folder.refusal(in: "ERROR 1045 (28000): Access denied for user 'alice'") == nil)
    }

    // Stand-ins for a client build: one that answers a plain-text request from a plugin built into it, and one that
    // hangs up because the plugin is not in the folder. Bash, dd and od, because the check passes the tool no PATH.
    private func fakeClient(sendsPassword: Bool) throws -> URL {
        let script = """
            #!/bin/bash
            while [ $# -gt 0 ]; do
                [ "$1" = "-P" ] && port=$2
                shift
            done
            exec 3<>"/dev/tcp/127.0.0.1/$port"
            skip_packet() {
                set -- $(/bin/dd bs=1 count=4 2> /dev/null <&3 | /usr/bin/od -An -tu1)
                /bin/dd bs=1 count=$(($1 + ($2 << 8) + ($3 << 16))) 2> /dev/null <&3 > /dev/null
            }
            skip_packet
            { printf '\\051\\000\\000\\001'; /bin/dd bs=32 count=1 if=/dev/zero 2> /dev/null; printf 'tablepro\\000'; } >&3
            skip_packet
            if [ \(sendsPassword ? 1 : 0) = 1 ]; then
                printf "\\\\$(printf '%03o' $((${#MYSQL_PWD} + 1)))\\\\000\\\\000\\\\003" >&3
                printf '%s\\000' "$MYSQL_PWD" >&3
            fi
            exec 3>&-
            """
        let url = try temporaryDirectory().appendingPathComponent("mariadb-dump")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("A client with a plain-text plugin built in is caught by asking it", arguments: [true, false])
    func builtInPlaintextPluginIsCaught(sendsPassword: Bool) async throws {
        let client = try fakeClient(sendsPassword: sendsPassword)
        defer { try? FileManager.default.removeItem(at: client.deletingLastPathComponent()) }
        #expect(
            await MariaDBBuiltInPlaintextCheck.verdict(toolPath: client.path)
                == (sendsPassword ? .sendsPlaintext : .refusesPlaintext)
        )
    }

    @Test("A client that never answers is unknown, and asked again next time")
    func silentClientIsAskedAgain() async throws {
        let refusing = try fakeClient(sendsPassword: false)
        defer { try? FileManager.default.removeItem(at: refusing.deletingLastPathComponent()) }
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appendingPathComponent("ready")
        let client = folder.appendingPathComponent("mariadb")
        let script = """
            #!/bin/sh
            [ -e '\(ready.path)' ] || exit 0
            exec '\(refusing.path)' "$@"
            """
        try script.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)

        #expect(await MariaDBBuiltInPlaintextCheck.verdict(toolPath: client.path, timeout: 1) == .unknown)
        #expect(FileManager.default.createFile(atPath: ready.path, contents: nil))
        #expect(await MariaDBBuiltInPlaintextCheck.verdict(toolPath: client.path, timeout: 5) == .refusesPlaintext)
        #expect(await MariaDBBuiltInPlaintextCheck.verdict(toolPath: "/nonexistent/bin/mariadb-dump") == .unknown)
    }

    @Test("A dump that would hide the plugins refuses a client that has them built in")
    func builtInPlaintextPluginRefusesTheRun() async throws {
        let client = try fakeClient(sendsPassword: true)
        defer { try? FileManager.default.removeItem(at: client.deletingLastPathComponent()) }
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        let resolved = NativeDumpResolvedTool(name: "mariadb-dump", path: client.path, flavor: .mariadb)
        let request = NativeDumpDescriptor.Request(
            connection: connection(.disabled),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/out.sql"),
            password: nil
        )
        await #expect(throws: NativeDumpError.self) {
            try await tool.prepare(request, resolved, answering(""))
        }
        let missing = NativeDumpResolvedTool(name: "mariadb-dump", path: "/nonexistent/bin/mariadb-dump", flavor: .mariadb)
        await #expect(throws: NativeDumpError.self) {
            try await tool.prepare(request, missing, answering(""))
        }

        let required = NativeDumpDescriptor.Request(
            connection: connection(.required),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/out.sql"),
            password: nil
        )
        _ = try await tool.prepare(required, resolved, answering(""))
    }

    @Test("The plugin folder is removed when the tool exits and when it cannot launch")
    func runnerRemovesThePluginFolder() async throws {
        let ran = try MariaDBClientPluginFolder.make(from: nil)
        let runner = ProcessNativeDumpRunner(command: runnerCommand("/bin/sh", folder: ran))
        try runner.start()
        _ = await runner.result
        #expect(!FileManager.default.fileExists(atPath: ran.url.path))

        let unlaunched = try MariaDBClientPluginFolder.make(from: nil)
        let failing = ProcessNativeDumpRunner(command: runnerCommand("/nonexistent/tool", folder: unlaunched))
        #expect(throws: (any Error).self) { try failing.start() }
        #expect(!FileManager.default.fileExists(atPath: unlaunched.url.path))
    }

    private func runnerCommand(_ executable: String, folder: MariaDBClientPluginFolder) -> NativeDumpCommand {
        NativeDumpCommand(
            executable: URL(fileURLWithPath: executable),
            arguments: ["-c", "exit 0"],
            environment: [:],
            stderrByteCap: 64_000,
            clientPluginFolder: folder
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MySQLDumpPlaintextPasswordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class FinishingRunner: NativeDumpRunner, @unchecked Sendable {
    private let outcome: NativeDumpRunResult
    private(set) var started = false

    init(_ outcome: NativeDumpRunResult) {
        self.outcome = outcome
    }

    func start() throws {
        started = true
    }

    func cancel() {}

    var result: NativeDumpRunResult {
        get async { outcome }
    }
}

@MainActor
struct MySQLDumpPlaintextPasswordServiceTests {
    private func job(folder: URL) -> NativeDumpJob {
        .process(
            NativeDumpCommand(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: [:],
                stderrByteCap: 64_000,
                clientPluginFolder: MariaDBClientPluginFolder(url: folder)
            )
        )
    }

    private func failure(of service: NativeDumpService, running job: NativeDumpJob) async throws -> String? {
        let updates = service.stateUpdates()
        try service.run(job: job, database: "sales", fileURL: URL(fileURLWithPath: "/tmp/plaintext-refusal.sql"))
        for await state in updates {
            if case .failed(let message, _) = state { return message }
            if case .finished = state { return nil }
        }
        return nil
    }

    @Test("A server that asked for a hidden plugin fails with the TLS advice")
    func refusalBecomesTheMessage() async throws {
        let stderr = #"mariadb-dump: Got error: 2059: "Plugin dialog could not be loaded: dlopen(/x/dialog.so)" when trying to connect"#
        let runner = FinishingRunner(.init(exitCode: 2, stderr: stderr, wasCancelled: false))
        let service = NativeDumpService(kind: .restore, runnerFactory: { _ in runner })
        let message = try await failure(of: service, running: job(folder: URL(fileURLWithPath: "/nonexistent/folder")))
        #expect(message == MySQLClientArguments.plaintextPasswordRefusal)
    }

    @Test("Any other failure keeps the tool's own words")
    func otherFailuresKeepStderr() async throws {
        let stderr = "mariadb-dump: Got error: 1045: \"Access denied for user 'alice'\" when trying to connect"
        let runner = FinishingRunner(.init(exitCode: 2, stderr: stderr, wasCancelled: false))
        let service = NativeDumpService(kind: .restore, runnerFactory: { _ in runner })
        let message = try await failure(of: service, running: job(folder: URL(fileURLWithPath: "/nonexistent/folder")))
        #expect(message == stderr)
    }

    @Test("A cancel before the tool runs removes the plugin folder it never used")
    func cancelBeforeRunRemovesTheFolder() throws {
        let folder = try MariaDBClientPluginFolder.make(from: nil)
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let runner = FinishingRunner(.init(exitCode: 0, stderr: "", wasCancelled: false))
        let service = NativeDumpService(kind: .backup, runnerFactory: { _ in runner })
        service.cancel()
        try service.run(job: job(folder: folder.url), database: "sales", fileURL: URL(fileURLWithPath: "/tmp/cancelled.sql"))
        #expect(!runner.started)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }
}
