import Darwin
import Foundation
@testable import TableProCommandLine
import TableProMCP
import TableProMCPTestSupport
import Testing

final class RecordingConsole: CLIConsole, @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = ""
    private var standardError = ""

    var output: String { lock.withLock { standardOutput } }
    var errors: String { lock.withLock { standardError } }

    func out(_ text: String) {
        lock.withLock { standardOutput += text }
    }

    func err(_ text: String) {
        lock.withLock { standardError += text }
    }
}

final class MemoryTokenStore: CLITokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(_ token: String?) {
        self.token = token
    }

    var current: String? { lock.withLock { token } }

    func read() throws -> String? { current }

    func save(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    func delete() {
        lock.withLock { token = nil }
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var openedTargets: [[URL]] = []

    var calls: [String] { lock.withLock { entries } }
    var opened: [[URL]] { lock.withLock { openedTargets } }

    func record(_ call: String) {
        lock.withLock { entries.append(call) }
    }

    func open(_ targets: [URL]) {
        lock.withLock {
            entries.append("open")
            openedTargets.append(targets)
        }
    }
}

let stagingId = "6B9F7C2E-1D3A-4C5B-8E9F-0A1B2C3D4E5F"
let workDirectory = URL(fileURLWithPath: "/work", isDirectory: true)

struct Rig {
    let server: MockHttpServer
    let console = RecordingConsole()
    let tokens: MemoryTokenStore
    let log = CallLog()

    var reachable: CLIServerProbe {
        .reachable(CLIServerEndpoint(socketPath: server.socketPath, serverPID: getpid(), appPath: nil))
    }

    func run(
        _ arguments: [String],
        stdinIsTerminal: Bool = true,
        stdoutIsTerminal: Bool = false,
        stderrIsTerminal: Bool = true,
        stdin: String = "",
        probe: CLIServerProbe? = nil,
        files: Set<String> = []
    ) async -> CLIExitCode {
        let socketPath = server.socketPath
        let log = log
        let found = probe ?? reachable
        let environment = CLIEnvironment(
            console: console,
            terminal: CLITerminal(
                standardInput: stdinIsTerminal,
                standardOutput: stdoutIsTerminal,
                standardError: stderrIsTerminal
            ),
            tokenStore: tokens,
            app: CLIHostApp(
                url: URL(fileURLWithPath: "/Applications/TablePro.app", isDirectory: true),
                version: "9.8.7",
                bundleIdentifier: "com.TablePro"
            ),
            openServer: {
                log.record("openServer")
                return CLIServerEndpoint(socketPath: socketPath, serverPID: getpid(), appPath: nil)
            },
            findServer: {
                log.record("findServer")
                return found
            },
            pair: { _ in
                log.record("pair")
                return "tp_paired"
            },
            openTargets: { targets in log.open(targets) },
            readStandardInput: { stdin },
            readFile: { path in throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) },
            fileExists: { path in files.contains(path) },
            currentDirectory: workDirectory
        )
        return await TableProCommand.run(arguments: arguments, environment: environment)
    }

    // Answers by tool name, RPC method or path, so a test does not depend on the order of calls.
    func route(_ answers: [String: MockHttpResponse]) async {
        await server.setHandler { request in
            answers[request.header("Mcp-Name") ?? ""]
                ?? answers[request.header("Mcp-Method") ?? ""]
                ?? answers[request.path]
        }
    }

    func requests(named name: String) async -> [MockHttpRequest] {
        await server.requests.filter { $0.header("Mcp-Name") == name }
    }
}

func withRig(token: String? = "tp_stored", _ body: (Rig) async throws -> Void) async throws {
    let server = MockHttpServer()
    try await server.start()
    do {
        try await body(Rig(server: server, tokens: MemoryTokenStore(token)))
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func success(_ structured: JsonValue) throws -> MockHttpResponse {
    let result: JsonValue = .object([
        "content": .array([.object(["type": .string("text"), "text": .string(structured.jsonString())])]),
        "structuredContent": structured,
        "isError": .bool(false)
    ])
    return try rpc(.successResponse(JsonRpcSuccessResponse(id: .number(1), result: result)))
}

func toolError(_ text: String) throws -> MockHttpResponse {
    let result: JsonValue = .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "isError": .bool(true)
    ])
    return try rpc(.successResponse(JsonRpcSuccessResponse(id: .number(1), result: result)))
}

func rpc(_ message: JsonRpcMessage, status: Int = 200) throws -> MockHttpResponse {
    MockHttpResponse(status: status, headers: [("Content-Type", "application/json")], body: try JsonRpcCodec.encode(message))
}

func plainJson(_ text: String, status: Int) -> MockHttpResponse {
    MockHttpResponse(status: status, headers: [("Content-Type", "application/json")], body: Data(text.utf8))
}

func rows(_ columns: [String], _ values: [[JsonValue]], truncated: Bool = false) -> JsonValue {
    .object([
        "columns": .array(columns.map { .string($0) }),
        "rows": .array(values.map { .array($0) }),
        "row_count": .int(values.count),
        "rows_affected": .int(0),
        "is_truncated": .bool(truncated)
    ])
}

func listing(_ connections: [(id: String, name: String)]) throws -> MockHttpResponse {
    try success(.object(["connections": .array(connections.map { entry in
        .object(["id": .string(entry.id), "name": .string(entry.name), "type": .string("PostgreSQL")])
    })]))
}

func stagingListing() throws -> MockHttpResponse {
    try listing([(stagingId, "Staging")])
}

func arguments(of request: MockHttpRequest) throws -> JsonValue {
    let body = try JSONDecoder().decode(JsonValue.self, from: request.body)
    return try #require(body["params"]?["arguments"])
}
