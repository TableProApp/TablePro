//
//  ConnectToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectTool")
struct ConnectToolTests {
    private let tool = ConnectTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Opening a session is a write, so the tool needs the write scope")
    func metadata() throws {
        #expect(ConnectTool.name == "connect")
        #expect(ConnectTool.requiredScopes == [.toolsWrite])
        #expect(ConnectTool.annotations.readOnlyHint == false)
        let schema = ConnectTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id"])
        let output = try #require(ConnectTool.outputSchema)
        #expect(output["properties"]?["connection_id"] != nil)
    }

    @Test("Missing connection_id is a protocol error")
    func missingConnectionId() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([:]))
        }
    }

    @Test("A malformed connection id is a tool error the model can fix")
    func malformedConnectionId() async throws {
        let result = try await call(.object(["connection_id": .string("not-a-uuid")]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An unknown connection is reported as not found")
    func unknownConnectionIsNotFound() async throws {
        let result = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_found:") == true)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "timeout_seconds": .int(5)
            ]))
        }
    }
}
