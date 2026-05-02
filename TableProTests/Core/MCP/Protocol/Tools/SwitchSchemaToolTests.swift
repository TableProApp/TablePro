import Foundation
@testable import TablePro
import Testing

@Suite("SwitchSchemaTool")
struct SwitchSchemaToolTests {
    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(SwitchSchemaTool.name == "switch_schema")
        #expect(SwitchSchemaTool.requiredScopes == [.toolsWrite])
        let schema = SwitchSchemaTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == ["connection_id", "schema"])
    }

    @Test("Missing connection_id returns invalidParams")
    func missingConnectionId() async throws {
        let tool = SwitchSchemaTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["schema": .string("public")]),
                context: context,
                services: services
            )
        }
    }

    @Test("Missing schema returns invalidParams")
    func missingSchema() async throws {
        let tool = SwitchSchemaTool()
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
        let tool = SwitchSchemaTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string("not-a-uuid"),
                    "schema": .string("public")
                ]),
                context: context,
                services: services
            )
        }
    }
}
