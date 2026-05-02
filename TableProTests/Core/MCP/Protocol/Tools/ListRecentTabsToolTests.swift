import Foundation
@testable import TablePro
import Testing

@Suite("ListRecentTabsTool")
struct ListRecentTabsToolTests {
    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(ListRecentTabsTool.name == "list_recent_tabs")
        #expect(ListRecentTabsTool.requiredScopes == [.toolsRead])
        let schema = ListRecentTabsTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == [])
    }

    @Test("Empty arguments returns a successful result")
    func emptyArgumentsSucceed() async throws {
        let tool = ListRecentTabsTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        let result = try await tool.call(arguments: .object([:]), context: context, services: services)
        #expect(result.isError == false)
        #expect(result.content.isEmpty == false)
    }
}
