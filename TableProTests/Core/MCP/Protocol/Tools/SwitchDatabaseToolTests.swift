//
//  SwitchDatabaseToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SwitchDatabaseTool")
struct SwitchDatabaseToolTests {
    private let tool = SwitchDatabaseTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Switching the session database is a write and names both parameters")
    func metadata() {
        #expect(SwitchDatabaseTool.name == "switch_database")
        #expect(SwitchDatabaseTool.requiredScopes == [.toolsWrite])
        #expect(SwitchDatabaseTool.annotations.readOnlyHint == false)
        #expect(
            SwitchDatabaseTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
                == ["connection_id", "database"]
        )
    }

    @Test("Missing connection_id or database is a protocol error")
    func missingRequiredParameters() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["database": .string("shop")]))
        }
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        }
    }

    @Test("A malformed connection id is a tool error")
    func malformedConnectionId() async throws {
        let result = try await call(.object([
            "connection_id": .string("not-a-uuid"),
            "database": .string("shop")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An empty database name is reported rather than switching to nothing")
    func emptyDatabaseName() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "database": .string("")
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("A database passed as a number is a protocol error")
    func numericDatabaseIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "database": .int(1)
            ]))
        }
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "database": .string("shop"),
                "schema": .string("public")
            ]))
        }
    }
}
