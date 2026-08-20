//
//  MCPToolErrorSurfaceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private struct ThrowingTool: MCPToolImplementation {
    static let name = "throwing_test_tool"
    static let description = "A tool that raises whatever the test hands it."
    static let requiredScopes: Set<MCPScope> = [.toolsRead]
    static let inputSchema = MCPToolSchema.empty
    static let outputSchema: JsonValue? = MCPToolSchema.empty

    let error: Error

    func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        throw error
    }
}

private struct TestOnlyFailure: Error {
    let detail: String
}

@Suite("Tool errors reach the model as results, protocol errors stay errors")
struct MCPToolErrorSurfaceTests {
    private func result(for error: Error) async throws -> MCPToolCallResult {
        try await ThrowingTool(error: error).call(
            arguments: .object([:]),
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("A SQL failure comes back as a result with isError set so the model can self-correct")
    func queryFailureIsAToolResult() async throws {
        let result = try await result(
            for: MCPToolExecutionError.queryFailed("syntax error at or near \"SELEC\"")
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result) == "query_failed: syntax error at or near \"SELEC\"")
    }

    @Test("A timeout and a denied write also come back as results, not protocol errors")
    func timeoutAndDenialAreToolResults() async throws {
        let timedOut = try await result(for: MCPToolExecutionError.timedOut("Query timed out after 30 seconds"))
        #expect(timedOut.isError)
        #expect(MCPToolTestHarness.errorText(timedOut)?.hasPrefix("timeout:") == true)

        let denied = try await result(for: MCPToolExecutionError.denied("Writing needs the tools:write scope."))
        #expect(denied.isError)
        #expect(MCPToolTestHarness.errorText(denied)?.hasPrefix("denied:") == true)
    }

    @Test("A data-layer failure is translated into a tool result")
    func dataLayerErrorsAreTranslated() async throws {
        let notConnected = try await result(for: MCPDataLayerError.notConnected(UUID()))
        #expect(notConnected.isError)
        #expect(MCPToolTestHarness.errorText(notConnected)?.hasPrefix("not_connected:") == true)

        let forbidden = try await result(for: MCPDataLayerError.forbidden("Safe Mode is read-only"))
        #expect(forbidden.isError)
        #expect(MCPToolTestHarness.errorText(forbidden)?.hasPrefix("denied:") == true)
    }

    @Test("An unexpected failure becomes an internal-failure result with a redacted message")
    func unexpectedFailuresAreRedacted() async throws {
        let result = try await result(
            for: TestOnlyFailure(detail: "host=db.internal.example port=5432 user=admin")
        )
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.hasPrefix("internal_failure:"))
        #expect(!text.contains("db.internal.example"))
        #expect(!text.contains("admin"))
        #expect(!text.contains("5432"))
    }

    @Test("A protocol error keeps travelling as a protocol error")
    func protocolErrorsAreRethrown() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await result(for: MCPProtocolError.invalidParams(detail: "arguments must be a JSON object"))
        }
    }

    @Test("Cancellation is a protocol error, never an isError result")
    func cancellationIsAProtocolError() async throws {
        do {
            _ = try await result(for: CancellationError())
            Issue.record("Expected a cancellation protocol error")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.requestCancelled)
        }
    }

    @Test("An input-required signal passes through untouched")
    func inputRequiredPassesThrough() async throws {
        let signal = MCPInputRequired(
            inputRequests: [
                MCPElicitationRequest.approval(key: "approve_statement", message: "Allow?", detail: nil)
            ],
            requestState: "sealed"
        )
        do {
            _ = try await result(for: signal)
            Issue.record("Expected the input-required signal to propagate")
        } catch let thrown as MCPInputRequired {
            #expect(thrown.requestState == "sealed")
        }
    }
}

@Suite("tools/call error surface")
struct ToolsCallErrorSurfaceTests {
    private func handle(_ params: JsonValue?) async throws -> MCPResult {
        try await ToolsCallHandler(services: MCPToolTestHarness.services())
            .handle(params: params, context: MCPToolTestHarness.context(params: params))
    }

    @Test("An unknown tool is a JSON-RPC error, not a result")
    func unknownToolIsAProtocolError() async throws {
        do {
            _ = try await handle(.object(["name": .string("no_such_tool"), "arguments": .object([:])]))
            Issue.record("Expected an unknown tool to be a protocol error")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
            #expect(error.message.contains("no_such_tool"))
        }
    }

    @Test("Malformed params are a JSON-RPC error, not a result")
    func malformedParamsAreAProtocolError() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handle(nil)
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handle(.string("not an object"))
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await handle(.object(["arguments": .object([:])]))
        }
    }

    @Test("A tool execution failure is a successful result carrying isError")
    func executionFailureIsAResult() async throws {
        let result = try await handle(.object([
            "name": .string("list_tables"),
            "arguments": .object(["connection_id": .string("not-a-uuid")])
        ]))
        #expect(result.kind == .complete)
        #expect(result.payload["isError"]?.boolValue == true)
        #expect(result.payload["content"]?.arrayValue?.isEmpty == false)
    }

    @Test("tools/call results never carry a cache hint")
    func toolResultsAreNotCacheable() async throws {
        let result = try await handle(.object([
            "name": .string("list_tables"),
            "arguments": .object(["connection_id": .string("not-a-uuid")])
        ]))
        #expect(result.cacheHint == nil)
        let encoded = result.asJsonValue(era: .modern, serverInfo: nil)
        #expect(encoded["ttlMs"] == nil)
        #expect(encoded["cacheScope"] == nil)
        #expect(encoded["resultType"]?.stringValue == "complete")
    }

    @Test("A tool the token cannot reach is refused with a scope challenge")
    func insufficientScopeIsChallenged() async throws {
        let params = JsonValue.object([
            "name": .string("insert_rows"),
            "arguments": .object([:])
        ])
        do {
            _ = try await ToolsCallHandler(services: MCPToolTestHarness.services())
                .handle(
                    params: params,
                    context: MCPToolTestHarness.context(
                        params: params,
                        principal: MCPToolTestHarness.principal(scopes: [.toolsRead])
                    )
                )
            Issue.record("Expected the write tool to be refused")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.forbidden)
            #expect(error.extraHeaders.contains { $0.0 == "WWW-Authenticate" })
        }
    }
}

@Suite("MCPErrorRedactor")
struct MCPErrorRedactorTests {
    @Test("A host and port are stripped from a driver message")
    func hostsAndPortsAreStripped() {
        let redacted = MCPErrorRedactor.redact("could not connect to server at 10.0.0.5:5432")
        #expect(!redacted.contains("10.0.0.5"))
        #expect(!redacted.contains("5432"))
        #expect(redacted.contains("[redacted]"))

        let named = MCPErrorRedactor.redact("connection to db.internal.example:5432 refused")
        #expect(!named.contains("db.internal.example"))
    }

    @Test("Connection-string key-value pairs are stripped")
    func connectionStringPairsAreStripped() {
        let redacted = MCPErrorRedactor.redact(
            "FATAL: host=db.internal.example port=5432 user=admin password=hunter2 dbname=shop"
        )
        for secret in ["db.internal.example", "5432", "admin", "hunter2", "shop"] {
            #expect(!redacted.contains(secret), "\(secret) leaked")
        }
    }

    @Test("A DSN with credentials is stripped whole")
    func dsnIsStripped() {
        let redacted = MCPErrorRedactor.redact("postgresql://admin:hunter2@db.internal:5432/shop")
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("admin"))
        #expect(!redacted.contains("db.internal"))
    }

    @Test("A local file path is stripped")
    func filePathsAreStripped() {
        let redacted = MCPErrorRedactor.redact("unable to open /Users/alice/Databases/shop.sqlite")
        #expect(!redacted.contains("/Users/alice"))
        #expect(!redacted.contains("alice"))
    }

    @Test("The connection's own values are stripped even when the driver spells them plainly")
    func connectionSecretsAreStripped() {
        let redacted = MCPErrorRedactor.redact(
            "login failed for user reporting on production",
            secrets: ["reporting", "production", "5432"]
        )
        #expect(!redacted.contains("reporting"))
        #expect(!redacted.contains("production"))
        #expect(redacted.contains("[redacted]"))
    }

    @Test("A very short secret is not used as a redaction pattern")
    func shortSecretsAreIgnored() {
        let redacted = MCPErrorRedactor.redact("a table named ab was not found", secrets: ["ab"])
        #expect(redacted.contains("ab was not found"))
    }

    @Test("A long message is capped so a dump never reaches the client")
    func longMessagesAreCapped() {
        let redacted = MCPErrorRedactor.redact(String(repeating: "a", count: 1_000))
        #expect((redacted as NSString).length == MCPErrorRedactor.maximumLength + 1)
        #expect(redacted.hasSuffix("…"))
    }

    @Test("A tool error built from a data-layer error is redacted with the connection's secrets")
    func toolErrorsAreRedacted() {
        let error = MCPToolExecutionError.from(
            .dataSourceError("relation \"users\" does not exist on db.internal.example:5432"),
            secrets: ["db.internal.example"]
        )
        #expect(error.code == .queryFailed)
        #expect(!error.message.contains("db.internal.example"))
    }
}
