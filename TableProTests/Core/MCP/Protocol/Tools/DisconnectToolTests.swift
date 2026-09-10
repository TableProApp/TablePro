//
//  DisconnectToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("DisconnectTool")
struct DisconnectToolTests {
    private let tool = DisconnectTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Closing a session is a write, so the tool needs the write scope")
    func metadata() {
        #expect(DisconnectTool.name == "disconnect")
        #expect(DisconnectTool.requiredScopes == [.toolsWrite])
        #expect(DisconnectTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id"])
        #expect(DisconnectTool.outputSchema != nil)
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

    @Test("Disconnecting a session that is not open says so")
    func disconnectingAClosedSession() async throws {
        let result = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_connected:") == true)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "force": .bool(true)
            ]))
        }
    }
}
