import Foundation
import os

public struct ResourcesTemplatesListHandler: MCPMethodHandler {
    public static let method = "resources/templates/list"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Resources")

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        let templates: [JsonValue] = [
            .object([
                "uriTemplate": .string("tablepro://connections/{id}/schema"),
                "name": .string(String(localized: "Database Schema")),
                "description": .string(String(localized: "Tables, columns, indexes, and foreign keys for a connected database")),
                "mimeType": .string("application/json")
            ]),
            .object([
                "uriTemplate": .string("tablepro://connections/{id}/history"),
                "name": .string(String(localized: "Query History")),
                "description": .string(String(localized: "Recent query history for a connection (supports ?limit=, ?search=, ?date_filter=)")),
                "mimeType": .string("application/json")
            ])
        ]

        let result: JsonValue = .object(["resourceTemplates": .array(templates)])
        Self.logger.debug("resources/templates/list returned \(templates.count, privacy: .public) templates")
        return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
    }
}
