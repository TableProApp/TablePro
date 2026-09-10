import Foundation
import os

public struct ToolsListHandler: MCPMethodHandler {
    public static let method = "tools/list"
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")
    private static let cacheHint = MCPCacheHint.privateFor(seconds: 300)

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        let cursor = try MCPListPagination.cursorArgument(in: params)
        let visible = Self.visibleTools(for: context.principal)
        let page = try MCPListPagination.page(visible, cursor: cursor, method: Self.method)

        var payload: [String: JsonValue] = [
            "tools": .array(page.items.map { Self.descriptor(for: $0) })
        ]
        if let nextCursor = page.nextCursor {
            payload["nextCursor"] = .string(nextCursor)
        }

        Self.logger.debug(
            """
            tools/list page=\(page.items.count, privacy: .public) \
            visible=\(visible.count, privacy: .public)
            """
        )
        return .complete(payload, cacheHint: Self.cacheHint)
    }

    private static func visibleTools(for principal: MCPPrincipal) -> [any MCPToolImplementation] {
        MCPToolRegistry.allTools
            .filter { type(of: $0).requiredScopes.isSubset(of: principal.scopes) }
            .sorted { type(of: $0).name < type(of: $1).name }
    }

    private static func descriptor(for tool: any MCPToolImplementation) -> JsonValue {
        let toolType = type(of: tool)
        var fields: [String: JsonValue] = [
            "name": .string(toolType.name),
            "description": .string(toolType.description),
            "inputSchema": toolType.inputSchema
        ]
        if let title = toolType.title {
            fields["title"] = .string(title)
        }
        if let outputSchema = toolType.outputSchema {
            fields["outputSchema"] = outputSchema
        }
        if let annotations = toolType.annotations.asJsonValue {
            fields["annotations"] = annotations
        }
        let icons = toolType.icons.map(\.asJsonValue)
        if !icons.isEmpty {
            fields["icons"] = .array(icons)
        }
        return .object(fields)
    }
}
