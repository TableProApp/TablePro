import Foundation
@testable import TableProCommandLine
import TableProMCP
import TableProMCPTestSupport
import Testing

struct CLIQueryTests {
    @Test("CSV and TSV escape terminal controls and preserve pipe bytes", arguments: [true, false], ["csv", "tsv"])
    func delimitedControls(stdoutIsTerminal: Bool, format: String) async throws {
        try await withRig { rig in
            let text = "\u{1B}]52;c;eA==\u{07}\u{1B}[2J"
            await rig.route([
                "list_connections": try stagingListing(),
                "execute_query": try success(rows(["value"], [[.string(text)]]))
            ])
            let code = await rig.run(
                ["query", "-c", "Staging", "--format", format, "SELECT value FROM users"],
                stdoutIsTerminal: stdoutIsTerminal
            )
            #expect(code == .success)
            let expected = stdoutIsTerminal ? "value\n\\x1B]52;c;eA==\\x07\\x1B[2J\n" : "value\n" + text + "\n"
            #expect(rig.console.output == expected)
        }
    }

    @Test("SELECT 1 AS n prints a CSV header and one row and exits 0")
    func csvQuery() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], [[.string("1")]]))])
            let code = await rig.run(["query", "-c", "Staging", "--format", "csv", "SELECT 1 AS n"])
            #expect(code == .success)
            #expect(rig.console.output == "n\n1\n")
            #expect(rig.console.errors.isEmpty)

            let request = try #require(await rig.requests(named: "execute_query").first)
            #expect(request.path == "/mcp")
            #expect(request.header("Authorization") == "Bearer tp_stored")
            #expect(request.header("Mcp-Method") == "tools/call")
            let body = try JSONDecoder().decode(JsonValue.self, from: request.body)
            #expect(body["params"]?["_meta"]?[MCPMetaKeys.clientInfo]?["name"]?.stringValue == CLIClientIdentity.name)
            let sent = try arguments(of: request)
            #expect(sent["connection_id"]?.stringValue == stagingId)
            #expect(sent["query"]?.stringValue == "SELECT 1 AS n")
            #expect(sent["read_only"] == nil)
        }
    }

    @Test("--format takes any case")
    func formatIgnoresCase() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], [[.string("1")]]))])
            #expect(await rig.run(["query", "-c", "Staging", "--format", "JSON", "SELECT 1 AS n"]) == .success)
            #expect(rig.console.output == "[\n  {\"n\":\"1\"}\n]\n")
        }
    }

    @Test("Every option reaches execute_query under its own key")
    func everyOption() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], []))])
            let code = await rig.run([
                "query", "--connection=Staging", "--database", "app", "--schema=public",
                "--limit", "20", "--timeout", "5", "--read-only", "SELECT 1"
            ])
            #expect(code == .success)
            let sent = try arguments(of: try #require(await rig.requests(named: "execute_query").first))
            #expect(sent["database"]?.stringValue == "app")
            #expect(sent["schema"]?.stringValue == "public")
            #expect(sent["max_rows"]?.intValue == 20)
            #expect(sent["timeout_seconds"]?.intValue == 5)
            #expect(sent["read_only"]?.boolValue == true)
        }
    }

    @Test("SQL that starts with a dash is refused as an option, and taken after --")
    func dashSql() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], []))])
            let sql = "-- weekly report\nSELECT 1"
            #expect(await rig.run(["query", "-c", "Staging", sql]) == .usage)
            #expect(await rig.server.requests.isEmpty)

            #expect(await rig.run(["query", "-c", "Staging", "--", sql]) == .success)
            let sent = try arguments(of: try #require(await rig.requests(named: "execute_query").first))
            #expect(sent["query"]?.stringValue == sql)
        }
    }

    @Test("--read-only goes to the server, and its refusal exits 3")
    func readOnlyRefusal() async throws {
        try await withRig { rig in
            await rig.route([
                "list_connections": try stagingListing(),
                "execute_query": try toolError("denied: This request is read only, and the statement is not a read.")
            ])
            let code = await rig.run(["query", "-c", "Staging", "--read-only", "DELETE FROM t"])
            #expect(code == .refused)
            #expect(rig.console.output.isEmpty)
            #expect(rig.console.errors.contains("read only"))
        }
    }

    @Test("A statement timeout exits 4")
    func timeout() async throws {
        try await withRig { rig in
            await rig.route([
                "list_connections": try stagingListing(),
                "execute_query": try toolError("timeout: The query did not finish within 5 seconds.")
            ])
            #expect(await rig.run(["query", "-c", "Staging", "--timeout", "5", "SELECT pg_sleep(10)"]) == .timedOut)
        }
    }

    @Test("A revoked token is forgotten and the run exits 3")
    func revokedToken() async throws {
        try await withRig { rig in
            let failure = JsonRpcErrorResponse(id: nil, error: JsonRpcError(code: JsonRpcErrorCode.unauthenticated, message: "Unauthenticated"))
            await rig.server.setResponse(try rpc(.errorResponse(failure), status: 401))
            let code = await rig.run(["query", "-c", "Staging", "SELECT 1"])
            #expect(code == .refused)
            #expect(rig.tokens.current == nil)
            #expect(rig.console.errors.contains("revoked"))
            #expect(!rig.log.calls.contains("pair"))
        }
    }

    @Test("An unpaired command outside a terminal refuses instead of opening a pairing sheet")
    func noPairingWithoutTerminal() async throws {
        try await withRig(token: nil) { rig in
            let code = await rig.run(["query", "-c", "Staging", "SELECT 1"], stderrIsTerminal: false)
            #expect(code == .refused)
            #expect(!rig.log.calls.contains("pair"))
            #expect(await rig.server.requests.isEmpty)
        }
    }

    @Test("An unpaired command in a terminal pairs once and keeps the token")
    func pairsOnce() async throws {
        try await withRig(token: nil) { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], [[.string("1")]]))])
            #expect(await rig.run(["query", "-c", "Staging", "SELECT 1"]) == .success)
            #expect(rig.log.calls.filter { $0 == "pair" }.count == 1)
            #expect(rig.tokens.current == "tp_paired")
            #expect(await rig.server.requests.first?.header("Authorization") == "Bearer tp_paired")
        }
    }

    @Test("connections prints name, id and type, and nothing else")
    func connections() async throws {
        try await withRig { rig in
            let entries: JsonValue = .object(["connections": .array([
                .object([
                    "id": .string(stagingId), "name": .string("Staging"), "type": .string("PostgreSQL"),
                    "host": .string("db.internal"), "port": .int(5_432)
                ])
            ])])
            await rig.server.setResponse(try success(entries))
            #expect(await rig.run(["connections", "--format", "json"]) == .success)
            #expect(rig.console.output == "[\n  {\"name\":\"Staging\",\"id\":\"\(stagingId)\",\"type\":\"PostgreSQL\"}\n]\n")
        }
    }

    @Test("A cut-short result says so on standard error")
    func truncatedNote() async throws {
        try await withRig { rig in
            await rig.route([
                "list_connections": try stagingListing(),
                "execute_query": try success(rows(["n"], [[.string("1")]], truncated: true))
            ])
            #expect(await rig.run(["query", "-c", "Staging", "--limit", "1", "SELECT n FROM t"]) == .success)
            #expect(rig.console.errors == "tablepro: showing the first row. Pass --limit to change it.\n")
        }
    }

    @Test("Every result set of a script is printed")
    func resultSets() async throws {
        try await withRig { rig in
            var primary = rows(["a"], [[.string("1")]]).objectValue ?? [:]
            primary["result_sets"] = .array([rows(["a"], [[.string("1")]]), rows(["b"], [[.string("2")]])])
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(.object(primary))])
            let code = await rig.run(["query", "-c", "Staging", "--format", "csv", "SELECT 1 AS a\nGO\nSELECT 2 AS b"])
            #expect(code == .success)
            #expect(rig.console.output == "a\n1\n\nb\n2\n")
        }
    }

    @Test("SQL comes from standard input when it is piped")
    func pipedInput() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], [[.string("1")]]))])
            #expect(await rig.run(["query", "-c", "Staging"], stdinIsTerminal: false, stdin: "SELECT 1\n") == .success)
            let sent = try arguments(of: try #require(await rig.requests(named: "execute_query").first))
            #expect(sent["query"]?.stringValue == "SELECT 1\n")
        }
    }

    @Test("-f - reads standard input even from a terminal")
    func explicitStandardInputOnTerminal() async throws {
        try await withRig { rig in
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(rows(["n"], [[.string("1")]]))])
            #expect(await rig.run(["query", "-c", "Staging", "-f", "-"], stdinIsTerminal: true, stdin: "SELECT 2\n") == .success)
            let sent = try arguments(of: try #require(await rig.requests(named: "execute_query").first))
            #expect(sent["query"]?.stringValue == "SELECT 2\n")
        }
    }

    @Test("No SQL from a terminal, an empty statement, or an unreadable file is a usage error")
    func missingSql() async throws {
        try await withRig { rig in
            #expect(await rig.run(["query", "-c", "Staging"]) == .usage)
            #expect(await rig.run(["query", "-c", "Staging", "   "]) == .usage)
            #expect(await rig.run(["query", "-c", "Staging", "-f", "/nope.sql"]) == .usage)
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
            await rig.route(["list_connections": try stagingListing(), "execute_query": try success(result)])
            #expect(await rig.run(["query", "-c", "Staging", "UPDATE t SET a = 1"]) == .success)
            #expect(rig.console.output.isEmpty)
            #expect(rig.console.errors == "3 rows affected.\n")
        }
    }

    @Test("A database error is shown with its escape sequences escaped")
    func errorTextIsEscaped() async throws {
        try await withRig { rig in
            await rig.route([
                "list_connections": try stagingListing(),
                "execute_query": try toolError("query_failed: invalid input syntax for type integer: \"x\u{1B}]52;c;SGk=\u{07}\u{1B}[2J\"")
            ])
            #expect(await rig.run(["query", "-c", "Staging", "SELECT note::int FROM t"]) == .failure)
            #expect(!rig.console.errors.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
            #expect(rig.console.errors.contains("\\x1B]52;c;SGk=\\x07\\x1B[2J"))
        }
    }
}
