import Foundation
@testable import TablePro
import Testing

@Suite("ToolsCallHandler")
struct ToolsCallHandlerTests {
    @Test("Unknown tool returns method not found")
    func unknownTool() async throws {
        let handler = makeHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let params: JsonValue = .object([
            "name": .string("nonexistent_tool"),
            "arguments": .object([:])
        ])

        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: params, context: context)
        }
    }

    @Test("Missing tool name returns invalid params")
    func missingToolName() async throws {
        let handler = makeHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let params: JsonValue = .object(["arguments": .object([:])])

        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: params, context: context)
        }
    }

    @Test("Non-object params return invalid params")
    func nonObjectParams() async throws {
        let handler = makeHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let params: JsonValue = .string("oops")

        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: params, context: context)
        }
    }

    @Test("Insufficient scope returns forbidden")
    func insufficientScope() async throws {
        let handler = makeHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: "tools/call",
            principalScopes: []
        )
        let params: JsonValue = .object([
            "name": .string("list_connections"),
            "arguments": .object([:])
        ])

        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: params, context: context)
        }
    }

    @Test("list_connections returns content array")
    func listConnectionsHappyPath() async throws {
        let handler = makeHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let params: JsonValue = .object([
            "name": .string("list_connections"),
            "arguments": .object([:])
        ])

        let response = try await handler.handle(params: params, context: context)
        guard case .successResponse(let success) = response else {
            Issue.record("expected success, got \(response)")
            return
        }
        let content = success.result["content"]?.arrayValue
        #expect(content != nil)
        #expect(content?.first?["type"]?.stringValue == "text")
    }

    @Test("list_connections includes structuredContent for 2025-11-25 clients")
    func listConnectionsExposesStructuredContent() async throws {
        let handler = makeHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let params: JsonValue = .object([
            "name": .string("list_connections"),
            "arguments": .object([:])
        ])

        let response = try await handler.handle(params: params, context: context)
        guard case .successResponse(let success) = response else {
            Issue.record("expected success, got \(response)")
            return
        }
        let structured = success.result["structuredContent"]
        #expect(structured != nil)
        if case .object = structured {
            // ok
        } else {
            Issue.record("expected structuredContent to be an object")
        }
    }

    @Test("get_table_ddl with missing connection_id returns invalid params")
    func getTableDdlMissingId() async throws {
        let handler = makeHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let params: JsonValue = .object([
            "name": .string("get_table_ddl"),
            "arguments": .object([
                "table": .string("users")
            ])
        ])

        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: params, context: context)
        }
    }

    @Test("list_tables with malformed connection_id returns invalid params")
    func listTablesMalformedId() async throws {
        let handler = makeHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let params: JsonValue = .object([
            "name": .string("list_tables"),
            "arguments": .object([
                "connection_id": .string("not-a-uuid")
            ])
        ])

        await #expect(throws: MCPProtocolError.self) {
            _ = try await handler.handle(params: params, context: context)
        }
    }

    private func makeHandler() -> ToolsCallHandler {
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )
        return ToolsCallHandler(services: services)
    }
}
