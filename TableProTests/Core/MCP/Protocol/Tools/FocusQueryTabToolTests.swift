import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("FocusQueryTabTool")
struct FocusQueryTabToolTests {
    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(FocusQueryTabTool.name == "focus_query_tab")
        #expect(FocusQueryTabTool.requiredScopes == [.toolsRead])
        let schema = FocusQueryTabTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == ["tab_id"])
    }

    @Test("Missing tab_id returns invalidParams")
    func missingTabId() async throws {
        let tool = FocusQueryTabTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(arguments: .object([:]), context: context, services: services)
        }
    }

    @Test("Malformed tab_id returns invalidParams")
    func malformedTabId() async throws {
        let tool = FocusQueryTabTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["tab_id": .string("not-a-uuid")]),
                context: context,
                services: services
            )
        }
    }
}
