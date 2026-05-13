import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SwitchDatabaseTool")
struct SwitchDatabaseToolTests {
    @Test("Tool requires write scope")
    func requiresWriteScope() {
        #expect(SwitchDatabaseTool.requiredScopes == [.toolsWrite])
        #expect(SwitchDatabaseTool.name == "switch_database")
    }

    @Test("Missing connection_id returns invalidParams")
    func missingConnectionId() async throws {
        let tool = SwitchDatabaseTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["database": .string("foo")]),
                context: context,
                services: services
            )
        }
    }

    @Test("Missing database returns invalidParams")
    func missingDatabase() async throws {
        let tool = SwitchDatabaseTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString)
                ]),
                context: context,
                services: services
            )
        }
    }

    @Test("Schema lists both required parameters")
    func schemaRequiredFields() {
        let schema = SwitchDatabaseTool.inputSchema
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.contains("connection_id"))
        #expect(required.contains("database"))
    }
}
