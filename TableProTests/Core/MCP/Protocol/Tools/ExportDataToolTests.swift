import Foundation
@testable import TablePro
import Testing

@Suite("ExportDataTool")
struct ExportDataToolTests {
    @Test("Tool exposes expected metadata")
    func metadata() {
        #expect(ExportDataTool.name == "export_data")
        #expect(ExportDataTool.requiredScopes == [.toolsRead])
        let schema = ExportDataTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required == ["connection_id", "format"])
    }

    @Test("Missing connection_id returns invalidParams")
    func missingConnectionId() async throws {
        let tool = ExportDataTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object(["format": .string("csv")]),
                context: context,
                services: services
            )
        }
    }

    @Test("Missing format returns invalidParams")
    func missingFormat() async throws {
        let tool = ExportDataTool()
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
        let tool = ExportDataTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string("not-a-uuid"),
                    "format": .string("csv"),
                    "query": .string("SELECT 1")
                ]),
                context: context,
                services: services
            )
        }
    }

    @Test("Neither query nor tables returns invalidParams")
    func missingQueryAndTables() async throws {
        let tool = ExportDataTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: MCPAuthPolicy())

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString),
                    "format": .string("csv")
                ]),
                context: context,
                services: services
            )
        }
    }
}
