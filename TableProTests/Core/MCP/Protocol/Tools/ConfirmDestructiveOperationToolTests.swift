//
//  ConfirmDestructiveOperationToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConfirmDestructiveOperationTool")
struct ConfirmDestructiveOperationToolTests {
    private let tool = ConfirmDestructiveOperationTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("The tool needs the write scope and declares itself destructive")
    func metadata() {
        #expect(ConfirmDestructiveOperationTool.name == "confirm_destructive_operation")
        #expect(ConfirmDestructiveOperationTool.requiredScopes == [.toolsWrite])
        #expect(ConfirmDestructiveOperationTool.annotations.destructiveHint == true)
        #expect(ConfirmDestructiveOperationTool.annotations.readOnlyHint == false)
        let required = ConfirmDestructiveOperationTool.inputSchema["required"]?
            .arrayValue?.compactMap(\.stringValue)
        #expect(required == ["connection_id", "query"])
        #expect(ConfirmDestructiveOperationTool.outputSchema != nil)
    }

    @Test("Approval comes from the user, not from a phrase the client types")
    func noConfirmationPhraseParameter() async throws {
        let properties = ConfirmDestructiveOperationTool.inputSchema["properties"]?.objectValue ?? [:]
        #expect(properties["confirmation_phrase"] == nil)

        do {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "query": .string("DROP TABLE users"),
                "confirmation_phrase": .string("I understand this is irreversible")
            ]))
            Issue.record("Expected the removed confirmation_phrase parameter to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
            #expect(error.message.contains("confirmation_phrase"))
        }
    }

    @Test("Missing connection_id or query is a protocol error")
    func missingRequiredParameters() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["query": .string("DROP TABLE users")]))
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        }
    }

    @Test("An empty query is reported as a tool error")
    func emptyQueryIsReported() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "query": .string("  ")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(.object([
            "connection_id": .string("not-a-uuid"),
            "query": .string("DROP TABLE users")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An unknown connection is reported before the statement is classified")
    func unknownConnectionIsNotFound() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "query": .string("DROP TABLE users")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_found:") == true)
    }

    @Test("Only a destructive statement belongs here, and the gate decides that")
    func onlyDestructiveStatementsQualify() {
        #expect(
            QueryClassifier.classifyTier("DROP TABLE users", databaseType: .postgresql) == .destructive
        )
        #expect(
            QueryClassifier.classifyTier("UPDATE users SET a = 1", databaseType: .postgresql) == .write
        )
        #expect(
            QueryClassifier.classifyTier("SELECT 1", databaseType: .postgresql) == .safe
        )
    }
}
