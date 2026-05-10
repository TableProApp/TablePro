import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ListConnectionsTool")
struct ListConnectionsToolTests {
    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(ListConnectionsTool.name == "list_connections")
        #expect(ListConnectionsTool.requiredScopes == [.toolsRead])
        let schema = ListConnectionsTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == [])
    }

    @Test("Empty arguments returns a successful result")
    func emptyArgumentsSucceed() async throws {
        let tool = ListConnectionsTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        let result = try await tool.call(arguments: .object([:]), context: context, services: services)
        #expect(result.isError == false)
        #expect(result.content.isEmpty == false)
    }
}
