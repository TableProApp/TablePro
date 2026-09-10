//
//  DescribeTableToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("DescribeTableTool")
struct DescribeTableToolTests {
    private let tool = DescribeTableTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Describing a table is read-only and returns columns, indexes and foreign keys")
    func metadata() throws {
        #expect(DescribeTableTool.name == "describe_table")
        #expect(DescribeTableTool.requiredScopes == [.toolsRead])
        #expect(DescribeTableTool.annotations.readOnlyHint == true)
        #expect(
            DescribeTableTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
                == ["connection_id", "table"]
        )
        let output = try #require(DescribeTableTool.outputSchema)
        let required = output["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.contains("columns"))
        #expect(required.contains("indexes"))
        #expect(required.contains("foreign_keys"))
    }

    @Test("Missing table or connection_id is a protocol error")
    func missingRequiredParameters() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["table": .string("users")]))
        }
    }

    @Test("An empty table name is reported as a tool error")
    func emptyTableName() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "table": .string("  ")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(.object([
            "connection_id": .string("not-a-uuid"),
            "table": .string("users")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An explicit database and schema are accepted as strings only")
    func scopeArgumentsAreTyped() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "table": .string("users"),
                "database": .int(1)
            ]))
        }
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "table": .string("users"),
                "include_ddl": .bool(true)
            ]))
        }
    }
}
