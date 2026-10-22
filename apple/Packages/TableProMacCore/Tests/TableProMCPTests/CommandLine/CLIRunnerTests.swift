import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import Testing

private final class RecordingConsole: CLIConsole, @unchecked Sendable {
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

private final class MemoryTokenStore: CLITokenStoring, @unchecked Sendable {
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

private final class PairingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func pair() -> String {
        lock.withLock { count += 1 }
        return "tp_paired"
    }
}

private struct Rig {
    let server: MockHttpServer
    let console = RecordingConsole()
    let tokens: MemoryTokenStore
    let pairing = PairingRecorder()

    func runner(stdinIsTerminal: Bool = true, stderrIsTerminal: Bool = true, stdin: String = "") -> CLIRunner {
        let port = Int(server.port)
        let pairing = pairing
        return CLIRunner(
            console: console,
            terminal: CLITerminal(standardInput: stdinIsTerminal, standardOutput: false, standardError: stderrIsTerminal),
            tokenStore: tokens,
            openServer: { CLIServerEndpoint(port: port, appPath: nil) },
            pair: { _ in pairing.pair() },
            readStandardInput: { stdin },
            readFile: { path in throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        )
    }
}

private func withRig(token: String? = "tp_stored", _ body: (Rig) async throws -> Void) async throws {
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

private func success(_ structured: JsonValue) throws -> MockHttpResponse {
    let result: JsonValue = .object([
        "content": .array([.object(["type": .string("text"), "text": .string(structured.jsonString())])]),
        "structuredContent": structured,
        "isError": .bool(false)
    ])
    return try rpc(.successResponse(JsonRpcSuccessResponse(id: .number(1), result: result)))
}

private func toolError(_ text: String) throws -> MockHttpResponse {
    let result: JsonValue = .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "isError": .bool(true)
    ])
    return try rpc(.successResponse(JsonRpcSuccessResponse(id: .number(1), result: result)))
}

private func rpc(_ message: JsonRpcMessage, status: Int = 200) throws -> MockHttpResponse {
    MockHttpResponse(status: status, headers: [("Content-Type", "application/json")], body: try JsonRpcCodec.encode(message))
}

private func rows(_ columns: [String], _ values: [[JsonValue]], truncated: Bool = false) -> JsonValue {
    .object([
        "columns": .array(columns.map { .string($0) }),
        "rows": .array(values.map { .array($0) }),
        "row_count": .int(values.count),
        "rows_affected": .int(0),
        "is_truncated": .bool(truncated)
    ])
}

private func arguments(of request: MockHttpRequest) throws -> JsonValue {
    let body = try JSONDecoder().decode(JsonValue.self, from: request.body)
    return try #require(body["params"]?["arguments"])
}

private let stagingId = "6B9F7C2E-1D3A-4C5B-8E9F-0A1B2C3D4E5F"

struct CLIRunnerTests {
    @Test("SELECT 1 AS n prints a CSV header and one row and exits 0")
    func csvQuery() async throws {
        try await withRig { rig in
            await rig.server.setResponse(try success(rows(["n"], [[.string("1")]])))
            let code = await rig.runner().run(arguments: ["query", "-c", stagingId, "--format", "csv", "SELECT 1 AS n"])
            #expect(code == .success)
            #expect(rig.console.output == "n\n1\n")
            #expect(rig.console.errors.isEmpty)

            let request = try #require(await rig.server.requests.first)
            #expect(request.path == "/mcp")
            #expect(request.header("Authorization") == "Bearer tp_stored")
            #expect(request.header("Mcp-Method") == "tools/call")
            #expect(request.header("Mcp-Name") == "execute_query")
            let body = try JSONDecoder().decode(JsonValue.self, from: request.body)
            #expect(body["params"]?["_meta"]?[MCPMetaKeys.clientInfo]?["name"]?.stringValue == CLIClientIdentity.name)
            let sent = try arguments(of: request)
            #expect(sent["connection_id"]?.stringValue == stagingId)
            #expect(sent["query"]?.stringValue == "SELECT 1 AS n")
            #expect(sent["read_only"] == nil)
        }
    }

    @Test("--read-only goes to the server, and its refusal exits 3")
    func readOnlyRefusal() async throws {
        try await withRig { rig in
            await rig.server.setResponse(try toolError("denied: This request is read only, and the statement is not a read."))
            let code = await rig.runner().run(arguments: ["query", "-c", stagingId, "--read-only", "DELETE FROM t"])
            #expect(code == .refused)
            #expect(rig.console.output.isEmpty)
            #expect(rig.console.errors.contains("read only"))
            let request = try #require(await rig.server.requests.first)
            #expect(try arguments(of: request)["read_only"]?.boolValue == true)
        }
    }

    @Test("A statement timeout exits 4")
    func timeout() async throws {
        try await withRig { rig in
            await rig.server.setResponse(try toolError("timeout: The query did not finish within 5 seconds."))
            let code = await rig.runner().run(arguments: ["query", "-c", stagingId, "--timeout", "5", "SELECT pg_sleep(10)"])
            #expect(code == .timedOut)
            let request = try #require(await rig.server.requests.first)
            #expect(try arguments(of: request)["timeout_seconds"]?.intValue == 5)
        }
    }

    @Test("A revoked token is forgotten and the run exits 3")
    func revokedToken() async throws {
        try await withRig { rig in
            let failure = JsonRpcErrorResponse(id: nil, error: JsonRpcError(code: JsonRpcErrorCode.unauthenticated, message: "Unauthenticated"))
            await rig.server.setResponse(try rpc(.errorResponse(failure), status: 401))
            let code = await rig.runner().run(arguments: ["query", "-c", stagingId, "SELECT 1"])
            #expect(code == .refused)
            #expect(rig.tokens.current == nil)
            #expect(rig.console.errors.contains("revoked"))
            #expect(rig.pairing.calls == 0)
        }
    }

    @Test("A connection name is resolved through list_connections, ignoring case")
    func nameResolution() async throws {
        try await withRig { rig in
            let listing: JsonValue = .object(["connections": .array([
                .object(["id": .string(stagingId), "name": .string("Staging"), "type": .string("PostgreSQL")]),
                .object(["id": .string(UUID().uuidString), "name": .string("Production"), "type": .string("MySQL")])
            ])])
            await rig.server.setResponses([try success(listing), try success(rows(["n"], [[.string("1")]]))])
            let code = await rig.runner().run(arguments: ["query", "-c", "staging", "SELECT 1"])
            #expect(code == .success)
            let requests = await rig.server.requests
            #expect(requests.map { $0.header("Mcp-Name") } == ["list_connections", "execute_query"])
            #expect(try arguments(of: requests[1])["connection_id"]?.stringValue == stagingId)
        }
    }

    @Test("Two connections with the same name are a usage error that lists their ids")
    func ambiguousName() async throws {
        try await withRig { rig in
            let listing: JsonValue = .object(["connections": .array([
                .object(["id": .string("A"), "name": .string("Dev"), "type": .string("SQLite")]),
                .object(["id": .string("B"), "name": .string("Dev"), "type": .string("SQLite")])
            ])])
            await rig.server.setResponse(try success(listing))
            let code = await rig.runner().run(arguments: ["query", "-c", "Dev", "SELECT 1"])
            #expect(code == .usage)
            #expect(rig.console.errors.contains("A, B"))
            #expect(await rig.server.requests.count == 1)
        }
    }

    @Test("An unpaired command outside a terminal refuses instead of opening a pairing sheet")
    func noPairingWithoutTerminal() async throws {
        try await withRig(token: nil) { rig in
            let code = await rig.runner(stderrIsTerminal: false).run(arguments: ["query", "-c", stagingId, "SELECT 1"])
            #expect(code == .refused)
            #expect(rig.pairing.calls == 0)
            #expect(await rig.server.requests.isEmpty)
        }
    }

    @Test("An unpaired command in a terminal pairs once and keeps the token")
    func pairsOnce() async throws {
        try await withRig(token: nil) { rig in
            await rig.server.setResponse(try success(rows(["n"], [[.string("1")]])))
            let code = await rig.runner().run(arguments: ["query", "-c", stagingId, "SELECT 1"])
            #expect(code == .success)
            #expect(rig.pairing.calls == 1)
            #expect(rig.tokens.current == "tp_paired")
            #expect(await rig.server.requests.first?.header("Authorization") == "Bearer tp_paired")
        }
    }

    @Test("connections prints name, id and type, and nothing else")
    func connections() async throws {
        try await withRig { rig in
            let listing: JsonValue = .object(["connections": .array([
                .object([
                    "id": .string(stagingId), "name": .string("Staging"), "type": .string("PostgreSQL"),
                    "host": .string("db.internal"), "port": .int(5_432)
                ])
            ])])
            await rig.server.setResponse(try success(listing))
            let code = await rig.runner().run(arguments: ["connections", "--format", "json"])
            #expect(code == .success)
            #expect(rig.console.output == "[\n  {\"name\":\"Staging\",\"id\":\"\(stagingId)\",\"type\":\"PostgreSQL\"}\n]\n")
        }
    }

    @Test("A cut-short result says so on standard error")
    func truncatedNote() async throws {
        try await withRig { rig in
            await rig.server.setResponse(try success(rows(["n"], [[.string("1")]], truncated: true)))
            let code = await rig.runner().run(arguments: ["query", "-c", stagingId, "--limit", "1", "SELECT n FROM t"])
            #expect(code == .success)
            #expect(rig.console.errors == "tablepro: showing the first row. Pass --limit to change it.\n")
        }
    }

    @Test("Every result set of a script is printed")
    func resultSets() async throws {
        try await withRig { rig in
            var primary = rows(["a"], [[.string("1")]]).objectValue ?? [:]
            primary["result_sets"] = .array([rows(["a"], [[.string("1")]]), rows(["b"], [[.string("2")]])])
            await rig.server.setResponse(try success(.object(primary)))
            let code = await rig.runner().run(arguments: ["query", "-c", stagingId, "--format", "csv", "SELECT 1 AS a\nGO\nSELECT 2 AS b"])
            #expect(code == .success)
            #expect(rig.console.output == "a\n1\n\nb\n2\n")
        }
    }

    @Test("SQL comes from standard input when it is piped")
    func standardInput() async throws {
        try await withRig { rig in
            await rig.server.setResponse(try success(rows(["n"], [[.string("1")]])))
            let code = await rig.runner(stdinIsTerminal: false, stdin: "SELECT 1\n").run(arguments: ["query", "-c", stagingId])
            #expect(code == .success)
            let request = try #require(await rig.server.requests.first)
            #expect(try arguments(of: request)["query"]?.stringValue == "SELECT 1\n")
        }
    }

    @Test("No SQL from a terminal, an empty statement, or an unreadable file is a usage error")
    func missingSql() async throws {
        try await withRig { rig in
            #expect(await rig.runner().run(arguments: ["query", "-c", stagingId]) == .usage)
            #expect(await rig.runner().run(arguments: ["query", "-c", stagingId, "   "]) == .usage)
            #expect(await rig.runner().run(arguments: ["query", "-c", stagingId, "-f", "/nope.sql"]) == .usage)
            #expect(await rig.server.requests.isEmpty)
        }
    }

    @Test("A write that returns no rows reports the count on standard error only")
    func rowsAffected() async throws {
        try await withRig { rig in
            let result: JsonValue = .object([
                "columns": .array([]), "rows": .array([]), "row_count": .int(0),
                "rows_affected": .int(3), "is_truncated": .bool(false)
            ])
            await rig.server.setResponse(try success(result))
            let code = await rig.runner().run(arguments: ["query", "-c", stagingId, "UPDATE t SET a = 1"])
            #expect(code == .success)
            #expect(rig.console.output.isEmpty)
            #expect(rig.console.errors == "3 rows affected.\n")
        }
    }
}
