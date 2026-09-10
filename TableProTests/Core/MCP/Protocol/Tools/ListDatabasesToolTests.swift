//
//  ListDatabasesToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ListDatabasesTool")
struct ListDatabasesToolTests {
    private let tool = ListDatabasesTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Listing databases is read-only and takes only a connection")
    func metadata() {
        #expect(ListDatabasesTool.name == "list_databases")
        #expect(ListDatabasesTool.requiredScopes == [.toolsRead])
        #expect(ListDatabasesTool.annotations.readOnlyHint == true)
        #expect(
            ListDatabasesTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id"]
        )
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

    @Test("A database name is not accepted here, so a typo is caught rather than ignored")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "database": .string("shop")
            ]))
        }
    }
}
