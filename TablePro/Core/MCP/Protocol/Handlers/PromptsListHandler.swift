import Foundation
import os

public struct PromptsListHandler: MCPMethodHandler {
    public static let method = "prompts/list"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Prompts")
    private static let cacheHint = MCPCacheHint.publicFor(seconds: 3_600)

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        let cursor = try MCPListPagination.cursorArgument(in: params)
        let prompts = MCPPromptCatalog.all
        let page = try MCPListPagination.page(prompts, cursor: cursor, method: Self.method)

        var payload: [String: JsonValue] = ["prompts": .array(page.items.map(\.asJsonValue))]
        if let nextCursor = page.nextCursor {
            payload["nextCursor"] = .string(nextCursor)
        }

        Self.logger.debug(
            """
            prompts/list page=\(page.items.count, privacy: .public) \
            total=\(prompts.count, privacy: .public)
            """
        )
        return .complete(payload, cacheHint: Self.cacheHint)
    }
}
