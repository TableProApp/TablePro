//
//  GetTableDdlToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("GetTableDdlTool")
struct GetTableDdlToolTests {
    private let tool = GetTableDdlTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Reading DDL is read-only and returns the statement it read")
    func metadata() throws {
        #expect(GetTableDdlTool.name == "get_table_ddl")
        #expect(GetTableDdlTool.requiredScopes == [.toolsRead])
        #expect(
            GetTableDdlTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
                == ["connection_id", "table"]
        )
        let output = try #require(GetTableDdlTool.outputSchema)
        #expect(output["properties"]?["ddl"] != nil)
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

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(.object([
            "connection_id": .string("not-a-uuid"),
            "table": .string("users")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "table": .string("users"),
                "pretty": .bool(true)
            ]))
        }
    }
}
