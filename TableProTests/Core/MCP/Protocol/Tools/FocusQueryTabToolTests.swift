//
//  FocusQueryTabToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("FocusQueryTabTool")
struct FocusQueryTabToolTests {
    private let tool = FocusQueryTabTool()

    private func call(
        _ arguments: JsonValue,
        access: ConnectionAccess = .all,
        connections: [UUID: MCPConnectionAuthSnapshot] = [:]
    ) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(
                principal: MCPToolTestHarness.principal(access: access)
            ),
            services: MCPToolTestHarness.services(
                authPolicy: MCPToolTestHarness.authPolicy(connections: connections)
            )
        )
    }

    @Test("Raising a window is a write, so the tool needs the write scope")
    func raisingAWindowNeedsWriteScope() throws {
        #expect(FocusQueryTabTool.name == "focus_query_tab")
        #expect(FocusQueryTabTool.requiredScopes == [.toolsWrite])
        #expect(FocusQueryTabTool.annotations.readOnlyHint == false)
        let required = FocusQueryTabTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["tab_id"])
        let output = try #require(FocusQueryTabTool.outputSchema)
        #expect(output["properties"]?["window_id"] != nil)
    }

    @Test("Missing tab_id is a protocol error")
    func missingTabId() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([:]))
        }
    }

    @Test("A malformed tab_id comes back as a tool error the model can fix")
    func malformedTabId() async throws {
        let result = try await call(.object(["tab_id": .string("not-a-uuid")]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("A tab this client may not reach is not found, and the refusal names nothing")
    func unreachableTabIsNotFound() async throws {
        let withheld = UUID()
        let result = try await call(
            .object(["tab_id": .string(UUID().uuidString)]),
            access: .limited([]),
            connections: [withheld: MCPToolTestHarness.snapshot(name: "Withheld")]
        )
        #expect(result.isError)
        let text = MCPToolTestHarness.errorText(result) ?? ""
        #expect(text.hasPrefix("not_found:"))
        #expect(!text.contains("Withheld"))
        #expect(!text.contains(withheld.uuidString))
    }

    @Test("An unknown tab id is not found rather than raising some other window")
    func unknownTabIsNotFound() async throws {
        let result = try await call(.object(["tab_id": .string(UUID().uuidString)]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_found:") == true)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "tab_id": .string(UUID().uuidString),
                "connection_id": .string(UUID().uuidString)
            ]))
        }
    }
}
