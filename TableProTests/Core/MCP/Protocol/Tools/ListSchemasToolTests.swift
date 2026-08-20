//
//  ListSchemasToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ListSchemasTool")
struct ListSchemasToolTests {
    private let tool = ListSchemasTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Listing schemas is read-only and reports the database it covered")
    func metadata() throws {
        #expect(ListSchemasTool.name == "list_schemas")
        #expect(ListSchemasTool.requiredScopes == [.toolsRead])
        let output = try #require(ListSchemasTool.outputSchema)
        #expect(output["required"]?.arrayValue?.compactMap(\.stringValue) == ["database", "schemas"])
    }

    @Test("Missing connection_id is a protocol error")
    func missingConnectionId() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([:]))
        }
    }

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(.object(["connection_id": .string("not-a-uuid")]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("A database passed as a number is an error")
    func numericDatabaseIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "database": .int(1)
            ]))
        }
    }

    @Test("A schema argument is not accepted here")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "schema": .string("public")
            ]))
        }
    }
}
