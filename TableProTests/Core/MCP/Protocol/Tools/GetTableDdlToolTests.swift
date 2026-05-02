import Foundation
@testable import TablePro
import Testing

@Suite("GetTableDdlTool")
struct GetTableDdlToolTests {
    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(GetTableDdlTool.name == "get_table_ddl")
        #expect(GetTableDdlTool.requiredScopes == [.toolsRead])
        let schema = GetTableDdlTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == ["connection_id", "table"])
    }

    @Test("Missing connection_id returns invalidParams")
    func missingConnectionId() async throws {
        let tool = GetTableDdlTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["table": .string("users")]),
                context: context,
                services: services
            )
        }
    }

    @Test("Missing table returns invalidParams")
    func missingTable() async throws {
        let tool = GetTableDdlTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["connection_id": .string(UUID().uuidString)]),
                context: context,
                services: services
            )
        }
    }

    @Test("Malformed connection_id returns invalidParams")
    func malformedConnectionId() async throws {
        let tool = GetTableDdlTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string("not-a-uuid"),
                    "table": .string("users")
                ]),
                context: context,
                services: services
            )
        }
    }
}
