import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ConnectTool")
struct ConnectToolTests {
    @Test("Missing connection_id returns invalidParams")
    func missingConnectionId() async throws {
        let tool = ConnectTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([:]),
                context: context,
                services: services
            )
        }
    }

    @Test("Malformed connection_id returns invalidParams")
    func malformedConnectionId() async throws {
        let tool = ConnectTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string("not-a-uuid")
                ]),
                context: context,
                services: services
            )
        }
    }

    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(ConnectTool.name == "connect")
        #expect(ConnectTool.requiredScopes == [.toolsRead])
        let schema = ConnectTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["connection_id"])
    }
}
