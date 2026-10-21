//
//  MySQLDumpPlaintextPasswordTests.swift
//  TableProTests
//

import Foundation
import Network
import os
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
        #expect(!MySQLClientArguments.needsServerGreeting(socket, flavor: .mariadb))

        var proxied = connection(.preferred)
        proxied.additionalFields[DatabaseConnection.tunnelSecuresTransportKey] = "true"
        #expect(try command(proxied).clientPluginFolder == nil)
        #expect(!MySQLClientArguments.needsServerGreeting(proxied, flavor: .mariadb))
    }

    @Test("MySQL's own tools are left as they are")
    func mysqlToolsUntouched() throws {
        for mode in [SSLMode.disabled, .preferred] {
            let built = try command(connection(mode), flavor: .mysql, serverOffersTLS: false)
            #expect(built.clientPluginFolder == nil)
            #expect(pluginDirectoryArgument(built) == nil)
            #expect(!MySQLClientArguments.needsServerGreeting(connection(mode), flavor: .mysql))
        }
        #expect(try command(connection(.preferred), flavor: .mysql).arguments.contains("--ssl-mode=PREFERRED"))
    }

    @Test("Only a MariaDB tool on Preferred reads the server's greeting")
    func greetingIsReadOnlyForPreferred() async throws {
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        let client = try fakeClient(sendsPassword: false)
        defer { try? FileManager.default.removeItem(at: client.deletingLastPathComponent()) }
        for (mode, flavor) in [(SSLMode.disabled, NativeDumpToolFlavor.mariadb), (.required, .mariadb), (.preferred, .mysql)] {
            let request = NativeDumpDescriptor.Request(
                connection: connection(mode),
                database: "sales",
                fileURL: URL(fileURLWithPath: "/tmp/out.sql"),
                password: nil
            )
            let resolved = NativeDumpResolvedTool(name: "mariadb-dump", path: client.path, flavor: flavor)
            #expect(try await tool.prepare(request, resolved).serverOffersTLS == nil, "\(mode.rawValue) \(flavor)")
        }
    }

    private func preferredRequest(port: Int) -> NativeDumpDescriptor.Request {
        var preferred = connection(.preferred)
        preferred.host = "127.0.0.1"
        preferred.port = port
        return NativeDumpDescriptor.Request(
            connection: preferred,
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/out.sql"),
            password: nil
        )
    }

    @Test("Preferred takes the server's own answer from its greeting", arguments: [true, false])
    func preferredReadsTheGreeting(offersTLS: Bool) async throws {
        let server = try await FakeGreetingServer.start(payload: Self.greeting(offersTLS: offersTLS))
        defer { server.stop() }
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        let client = try fakeClient(sendsPassword: false)
        defer { try? FileManager.default.removeItem(at: client.deletingLastPathComponent()) }
        let resolved = NativeDumpResolvedTool(name: "mariadb-dump", path: client.path, flavor: .mariadb)
        #expect(try await tool.prepare(preferredRequest(port: server.port), resolved).serverOffersTLS == offersTLS)
        #expect(await MySQLServerGreeting.read(host: "127.0.0.1", port: server.port) == .offersTLS(offersTLS))
    }

    // Guessing no TLS would dump in plaintext from a server that has it; guessing TLS brings back the fallback.
    @Test("A server that cannot be read fails the run instead of a guess")
    func unreadableServerFailsTheRun() async throws {
        let tool = try #require(NativeDumpRegistry.descriptor(for: .mysql)?.commandLineTool)
        let resolved = NativeDumpResolvedTool(name: "mariadb-dump", path: "/t", flavor: .mariadb)
        let closed = try #require(LoopbackPort.allocateFree())
        await #expect(throws: NativeDumpError.self) {
            try await tool.prepare(preferredRequest(port: closed), resolved)
        }

        let busy = [0xFF, 0x10, 0x04] + Array("Too many connections".utf8)
        let server = try await FakeGreetingServer.start(payload: busy)
        defer { server.stop() }
        await #expect(throws: NativeDumpError.unreachableServer(message: "Too many connections")) {
            try await tool.prepare(preferredRequest(port: server.port), resolved)
        }
    }

    @Test("An error packet carries the server's words, and a short greeting tells nothing")
    func greetingParsing() {
        #expect(MySQLServerGreeting.answer(greeting: Self.greeting(offersTLS: true)) == .offersTLS(true))
        #expect(MySQLServerGreeting.answer(greeting: Self.greeting(offersTLS: false)) == .offersTLS(false))
        #expect(
            MySQLServerGreeting.answer(greeting: [0xFF, 0x69, 0x04] + Array("Host 'x' is blocked".utf8))
                == .serverError("Host 'x' is blocked")
        )
        #expect(
            MySQLServerGreeting.answer(greeting: [0xFF, 0x10, 0x04] + Array("#08004Too many connections".utf8))
                == .serverError("Too many connections")
        )
        #expect(MySQLServerGreeting.answer(greeting: [0xFF, 0x10, 0x04]) == .unreadable)
        #expect(MySQLServerGreeting.answer(greeting: [10] + Array("8.0.36".utf8)) == .unreadable)
        #expect(MySQLServerGreeting.answer(greeting: Array(Self.greeting(offersTLS: true).prefix(20))) == .unreadable)
        #expect(MySQLServerGreeting.answer(greeting: []) == .unreadable)
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
            try await tool.prepare(request, resolved)
        }
        let missing = NativeDumpResolvedTool(name: "mariadb-dump", path: "/nonexistent/bin/mariadb-dump", flavor: .mariadb)
        await #expect(throws: NativeDumpError.self) {
            try await tool.prepare(request, missing)
        }

        let required = NativeDumpDescriptor.Request(
            connection: connection(.required),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/out.sql"),
            password: nil
        )
        _ = try await tool.prepare(required, resolved)
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

    static func greeting(offersTLS: Bool) -> [UInt8] {
        let capabilities: UInt32 = 0x1 | 0x8 | 0x200 | 0x2000 | 0x8000 | 0x80000 | (offersTLS ? 0x800 : 0)
        var payload: [UInt8] = [10] + Array("8.0.36".utf8) + [0]
        payload += [1, 0, 0, 0] + Array("abcdefgh".utf8) + [0]
        payload += [UInt8(capabilities & 0xFF), UInt8((capabilities >> 8) & 0xFF), 45, 2, 0]
        payload += [UInt8((capabilities >> 16) & 0xFF), UInt8((capabilities >> 24) & 0xFF), 21] + [UInt8](repeating: 0, count: 10)
        payload += Array("ijklmnopqrst".utf8) + [0] + Array("caching_sha2_password".utf8) + [0]
        return payload
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

    @Test("A cancel while the checks run stops them and reads as cancelled", .timeLimit(.minutes(1)))
    func cancelDuringPreparation() async throws {
        let service = NativeDumpService(kind: .restore, runnerFactory: { _ in
            FinishingRunner(.init(exitCode: 0, stderr: "", wasCancelled: false))
        })
        let request = NativeDumpDescriptor.Request(
            connection: DatabaseConnection(name: "Test", host: "db.example.com", port: 3_306, type: .mysql),
            database: "sales",
            fileURL: URL(fileURLWithPath: "/tmp/cancelled.sql"),
            password: nil
        )
        let (started, signal) = AsyncStream<Void>.makeStream()
        let pending = Task {
            try await service.prepare(request) { request in
                signal.yield()
                try await Task.sleep(for: .seconds(60))
                return request
            }
        }
        for await _ in started { break }
        service.cancel()
        let prepared = try await pending.value
        #expect(prepared == nil)
        #expect(service.state == .cancelled)
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

private final class FakeGreetingServer: @unchecked Sendable {
    private let listener: NWListener
    let port: Int

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start(payload: [UInt8]) async throws -> FakeGreetingServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "com.TablePro.tests.FakeGreetingServer")
        let packet = Data([UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF), 0, 0] + payload)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                let value: Result<Int, any Error>?
                switch state {
                case .ready:
                    value = listener.port.map { .success(Int($0.rawValue)) } ?? .failure(CancellationError())
                case .failed(let error):
                    value = .failure(error)
                case .cancelled:
                    value = .failure(CancellationError())
                default:
                    value = nil
                }
                guard let value else { return }
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: value) }
            }
            listener.start(queue: queue)
        }
        return FakeGreetingServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }
}
