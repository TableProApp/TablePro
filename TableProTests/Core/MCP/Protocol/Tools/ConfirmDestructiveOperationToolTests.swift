import Foundation
@testable import TablePro
import Testing

@Suite("ConfirmDestructiveOperationTool")
struct ConfirmDestructiveOperationToolTests {
    @Test("Tool requires write scope")
    func requiresWriteScope() {
        #expect(ConfirmDestructiveOperationTool.requiredScopes == [.toolsWrite])
        #expect(ConfirmDestructiveOperationTool.name == "confirm_destructive_operation")
    }

    @Test("Wrong confirmation phrase returns invalidParams")
    func wrongConfirmationPhrase() async throws {
        let tool = ConfirmDestructiveOperationTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )
        let connectionId = UUID()

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(connectionId.uuidString),
                    "query": .string("DROP TABLE users"),
                    "confirmation_phrase": .string("yes do it")
                ]),
                context: context,
                services: services
            )
        }
    }

    @Test("Missing query returns invalidParams")
    func missingQuery() async throws {
        let tool = ConfirmDestructiveOperationTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        await #expect(throws: MCPProtocolError.self) {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString),
                    "confirmation_phrase": .string("I understand this is irreversible")
                ]),
                context: context,
                services: services
            )
        }
    }

    @Test("Multi-statement query is rejected before connection lookup")
    func multiStatementRejected() async throws {
        let tool = ConfirmDestructiveOperationTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )
        let connectionId = UUID()

        do {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(connectionId.uuidString),
                    "query": .string("DROP TABLE users; DROP TABLE other"),
                    "confirmation_phrase": .string("I understand this is irreversible")
                ]),
                context: context,
                services: services
            )
            Issue.record("Expected MCPProtocolError for multi-statement query")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("Tool input schema declares required fields")
    func inputSchemaRequiredFields() {
        let schema = ConfirmDestructiveOperationTool.inputSchema
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.contains("connection_id"))
        #expect(required.contains("query"))
        #expect(required.contains("confirmation_phrase"))
    }
}
