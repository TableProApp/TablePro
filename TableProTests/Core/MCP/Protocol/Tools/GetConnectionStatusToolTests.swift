//
//  GetConnectionStatusToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("GetConnectionStatusTool")
struct GetConnectionStatusToolTests {
    private let tool = GetConnectionStatusTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Reading status is read-only and reports the session fields")
    func metadata() throws {
        #expect(GetConnectionStatusTool.name == "get_connection_status")
        #expect(GetConnectionStatusTool.requiredScopes == [.toolsRead])
        #expect(GetConnectionStatusTool.annotations.readOnlyHint == true)
        let output = try #require(GetConnectionStatusTool.outputSchema)
        #expect(output["properties"]?["status"] != nil)
        #expect(output["properties"]?["current_database"] != nil)
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

    @Test("A session that is not open reports that rather than inventing a status")
    func closedSessionIsReported() async throws {
        let result = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_connected:") == true)
    }
}
