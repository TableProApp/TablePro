import Foundation
@testable import TablePro
import Testing

@Suite("SearchQueryHistoryTool")
struct SearchQueryHistoryToolTests {
    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(SearchQueryHistoryTool.name == "search_query_history")
        #expect(SearchQueryHistoryTool.requiredScopes == [.toolsRead])
        let schema = SearchQueryHistoryTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == ["query"])
    }

    @Test("Missing query returns invalidParams")
    func missingQuery() async throws {
        let tool = SearchQueryHistoryTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(arguments: .object([:]), context: context, services: services)
        }
    }

    @Test("Malformed connection_id returns invalidParams")
    func malformedConnectionId() async throws {
        let tool = SearchQueryHistoryTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "query": .string("select"),
                    "connection_id": .string("not-a-uuid")
                ]),
                context: context,
                services: services
            )
        }
    }
}
