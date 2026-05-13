import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("OpenTableTabTool")
struct OpenTableTabToolTests {
    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(OpenTableTabTool.name == "open_table_tab")
        #expect(OpenTableTabTool.requiredScopes == [.toolsRead])
        let schema = OpenTableTabTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == ["connection_id", "table_name"])
    }

    @Test("Missing connection_id returns invalidParams")
    func missingConnectionId() async throws {
        let tool = OpenTableTabTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["table_name": .string("users")]),
                context: context,
                services: services
            )
        }
    }

    @Test("Missing table_name returns invalidParams")
    func missingTableName() async throws {
        let tool = OpenTableTabTool()
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
        let tool = OpenTableTabTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string("not-a-uuid"),
                    "table_name": .string("users")
                ]),
                context: context,
                services: services
            )
        }
    }
}
