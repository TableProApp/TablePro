import Foundation
@testable import TablePro
import Testing

@Suite("ToolsListHandler")
struct ToolsListHandlerTests {
    @Test("Lists all 19 tools from the registry")
    func listsAllRegisteredTools() async throws {
        let response = try await runToolsList()
        let names = response["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []

        let expected: Set<String> = [
            "list_connections",
            "get_connection_status",
            "list_databases",
            "list_schemas",
            "list_tables",
            "describe_table",
            "get_table_ddl",
            "list_recent_tabs",
            "search_query_history",
            "focus_query_tab",
            "connect",
            "disconnect",
            "switch_database",
            "switch_schema",
            "execute_query",
            "export_data",
            "confirm_destructive_operation",
            "open_table_tab",
            "open_connection_window"
        ]

        #expect(Set(names) == expected)
        #expect(names.count == 19)
    }

    @Test("Each tool has name, description, and inputSchema")
    func eachToolHasShapeFields() async throws {
        let response = try await runToolsList()
        let tools = response["tools"]?.arrayValue ?? []

        for tool in tools {
            let name = tool["name"]?.stringValue
            let description = tool["description"]?.stringValue
            let schema = tool["inputSchema"]
            #expect(name != nil)
            #expect(description?.isEmpty == false)
            #expect(schema != nil)
        }
    }

    @Test("Each input schema is a JSON Schema object")
    func inputSchemasAreObjects() async throws {
        let response = try await runToolsList()
        let tools = response["tools"]?.arrayValue ?? []

        for tool in tools {
            guard case .object(let schema) = tool["inputSchema"] else {
                Issue.record("inputSchema not an object for tool \(tool["name"]?.stringValue ?? "?")")
                continue
            }
            #expect(schema["type"]?.stringValue == "object")
            #expect(schema["properties"] != nil)
            #expect(schema["required"] != nil)
        }
    }

    private func runToolsList() async throws -> JsonValue {
        let handler = ToolsListHandler()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/list")
        let message = try await handler.handle(params: nil, context: context)

        guard case .successResponse(let response) = message else {
            Issue.record("expected success response, got \(message)")
            return .null
        }
        return response.result
    }
}
