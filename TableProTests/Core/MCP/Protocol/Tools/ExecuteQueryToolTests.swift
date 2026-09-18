//
//  ExecuteQueryToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ExecuteQueryTool")
struct ExecuteQueryToolTests {
    private let tool = ExecuteQueryTool()

    private func call(
        _ arguments: JsonValue,
        context: MCPRequestContext? = nil,
        settings: MCPSettings = MCPSettings()
    ) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: context ?? MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services(settings: settings)
        )
    }

    @Test("Reads need only the read scope and the result set schema is declared")
    func metadata() {
        #expect(ExecuteQueryTool.name == "execute_query")
        #expect(ExecuteQueryTool.requiredScopes == [.toolsRead])
        #expect(ExecuteQueryTool.annotations.readOnlyHint == false)
        let required = ExecuteQueryTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["connection_id", "query"])
        #expect(ExecuteQueryTool.outputSchema != nil)
        #expect(ExecuteQueryTool.outputSchema?["properties"]?["rows"] != nil)
        #expect(ExecuteQueryTool.outputSchema?["properties"]?["is_truncated"] != nil)
    }

    @Test("Missing connection_id or query is a protocol error")
    func missingRequiredParameters() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["query": .string("SELECT 1")]))
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        }
    }

    @Test("A query passed as a number is a protocol error, never coerced")
    func numericQueryIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "query": .int(1)
            ]))
        }
    }

    @Test("An empty query is reported as a tool error")
    func emptyQueryIsReported() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "query": .string("   ")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("A query past the 100KB limit is reported before anything runs")
    func oversizedQueryIsReported() async throws {
        let oversized = String(repeating: "a", count: ExecuteQueryTool.maximumQueryBytes + 1)
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "query": .string(oversized)
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.contains("100KB") == true)
    }

    @Test("An out-of-range timeout is reported rather than clamped")
    func outOfRangeTimeoutIsReported() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "query": .string("SELECT 1"),
            "timeout_seconds": .int(100_000)
        ]))
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.contains("timeout_seconds"))
        #expect(text.contains("300"))
    }

    @Test("An out-of-range max_rows is reported rather than clamped")
    func outOfRangeRowLimitIsReported() async throws {
        let result = try await call(
            .object([
                "connection_id": .string(UUID().uuidString),
                "query": .string("SELECT 1"),
                "max_rows": .int(1_000_000)
            ]),
            settings: MCPSettings(defaultRowLimit: 100, maxRowLimit: 1_000)
        )
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.contains("1000") == true)
    }

    @Test("An unknown connection is reported as not found")
    func unknownConnectionIsNotFound() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "query": .string("SELECT 1")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_found:") == true)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "query": .string("SELECT 1"),
                "dry_run": .bool(true)
            ]))
        }
    }

    @Test("A cancelled request is reported as cancelled, not as a query failure")
    func cancellationIsReported() async throws {
        let cancellation = MCPCancellationToken()
        await cancellation.cancel()
        do {
            _ = try await call(
                .object([
                    "connection_id": .string(UUID().uuidString),
                    "query": .string("SELECT 1")
                ]),
                context: MCPToolTestHarness.context(cancellation: cancellation)
            )
            Issue.record("Expected the cancelled request to be reported as cancelled")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.requestCancelled)
        }
    }

    @Test("Progress is streamed only when the client asked for it")
    func progressFollowsTheProgressToken() async throws {
        let withToken = ToolTestResponderSink()
        _ = try? await call(
            .object([
                "connection_id": .string(UUID().uuidString),
                "query": .string("SELECT 1")
            ]),
            context: MCPToolTestHarness.context(
                progressToken: .string("progress-1"),
                sink: withToken
            )
        )
        let methods = await withToken.notificationMethods()
        #expect(!methods.isEmpty)
        #expect(methods.allSatisfy { $0 == "notifications/progress" })

        let withoutToken = ToolTestResponderSink()
        _ = try? await call(
            .object([
                "connection_id": .string(UUID().uuidString),
                "query": .string("SELECT 1")
            ]),
            context: MCPToolTestHarness.context(sink: withoutToken)
        )
        #expect(await withoutToken.sseFrames.isEmpty)
        #expect(await withoutToken.streamOpened == false)
    }
}
