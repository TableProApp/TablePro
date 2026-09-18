import Foundation
import os

public struct ResourcesTemplatesListHandler: MCPMethodHandler {
    public static let method = "resources/templates/list"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Resources")
    private static let cacheHint = MCPCacheHint.publicFor(seconds: 3_600)

    public init() {}

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        let cursor = try MCPListPagination.cursorArgument(in: params)
        let page = try MCPListPagination.page(Self.templates(), cursor: cursor, method: Self.method)

        var payload: [String: JsonValue] = ["resourceTemplates": .array(page.items)]
        if let nextCursor = page.nextCursor {
            payload["nextCursor"] = .string(nextCursor)
        }

        Self.logger.debug("resources/templates/list page=\(page.items.count, privacy: .public)")
        return .complete(payload, cacheHint: Self.cacheHint)
    }

    private static func templates() -> [JsonValue] {
        [
            template(
                uriTemplate: ResourcesUriRoute.Template.schema,
                name: "connection_schema",
                title: String(localized: "Database Schema"),
                description: String(
                    localized: """
                    Tables and their columns for the database a connection is browsing. Capped at 100 tables.
                    """
                )
            ),
            template(
                uriTemplate: ResourcesUriRoute.Template.tables,
                name: "connection_tables",
                title: String(localized: "Table List"),
                description: String(
                    localized: """
                    Table and view names in a database. Pass database and schema to look outside the browsed one, \
                    and row_counts=true for approximate row counts.
                    """
                )
            ),
            template(
                uriTemplate: ResourcesUriRoute.Template.table,
                name: "table_description",
                title: String(localized: "Table Description"),
                description: String(
                    localized: "Columns, indexes, foreign keys and an approximate row count for one table."
                )
            ),
            template(
                uriTemplate: ResourcesUriRoute.Template.tableDefinition,
                name: "table_ddl",
                title: String(localized: "Table DDL"),
                description: String(localized: "The CREATE statement for one table, as the engine reports it.")
            ),
            template(
                uriTemplate: ResourcesUriRoute.Template.databases,
                name: "connection_databases",
                title: String(localized: "Database List"),
                description: String(localized: "Database names a connection can reach.")
            ),
            template(
                uriTemplate: ResourcesUriRoute.Template.schemas,
                name: "connection_schemas",
                title: String(localized: "Schema List"),
                description: String(
                    localized: "Schema names inside a database, on engines that have schemas."
                )
            ),
            template(
                uriTemplate: ResourcesUriRoute.Template.history,
                name: "connection_history",
                title: String(localized: "Query History"),
                description: String(
                    localized: """
                    Queries recently run against a connection, newest first. limit is 1 to 500 and defaults to 50, \
                    search matches the query text, and date_filter is today, thisWeek or thisMonth.
                    """
                )
            )
        ]
    }

    private static func template(
        uriTemplate: String,
        name: String,
        title: String,
        description: String
    ) -> JsonValue {
        .object([
            "uriTemplate": .string(uriTemplate),
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "mimeType": .string(ResourcesUriRoute.mimeType)
        ])
    }
}
