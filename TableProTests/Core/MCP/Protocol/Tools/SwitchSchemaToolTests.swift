//
//  SwitchSchemaToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SwitchSchemaTool")
struct SwitchSchemaToolTests {
    private let tool = SwitchSchemaTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Switching the session schema is a write and names both parameters")
    func metadata() {
        #expect(SwitchSchemaTool.name == "switch_schema")
        #expect(SwitchSchemaTool.requiredScopes == [.toolsWrite])
        #expect(
            SwitchSchemaTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
                == ["connection_id", "schema"]
        )
    }

    @Test("Missing connection_id or schema is a protocol error")
    func missingRequiredParameters() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["schema": .string("public")]))
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        }
    }

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(.object([
            "connection_id": .string("not-a-uuid"),
            "schema": .string("public")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An empty schema name is reported rather than switching to nothing")
    func emptySchemaName() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "schema": .string("   ")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "schema": .string("public"),
                "database": .string("shop")
            ]))
        }
    }
}
