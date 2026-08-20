import Foundation

public struct ListFavoriteTablesTool: MCPToolImplementation {
    public static let name = "list_favorite_tables"
    public static let title: String? = String(localized: "List Favorite Tables")
    public static let description = String(
        localized: "List the tables the user starred on a connection. A good hint at what matters in this database."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Favorite Tables"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: ["connection_id": MCPToolSchema.connectionId],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "favorites": MCPToolSchema.array(
                String(localized: "Starred tables, sorted"),
                of: MCPToolSchema.object(
                    properties: [
                        "name": MCPToolSchema.string(String(localized: "Table name")),
                        "database": MCPToolSchema.nullableString(String(localized: "Database it lives in")),
                        "schema": MCPToolSchema.nullableString(String(localized: "Schema it lives in"))
                    ],
                    required: ["name"]
                )
            )
        ],
        required: ["favorites"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        try await MCPToolAuthorization.requireReadAccess(
            connectionId,
            context: context,
            services: services
        )

        let entries = FavoriteTablesStorage.shared.favorites(for: connectionId)
        let payload = entries
            .sorted { lhs, rhs in
                let lhsDatabase = lhs.database ?? ""
                let rhsDatabase = rhs.database ?? ""
                if lhsDatabase != rhsDatabase { return lhsDatabase < rhsDatabase }
                let lhsSchema = lhs.schema ?? ""
                let rhsSchema = rhs.schema ?? ""
                if lhsSchema != rhsSchema { return lhsSchema < rhsSchema }
                return lhs.name < rhs.name
            }
            .map { entry -> JsonValue in
                .object([
                    "name": .string(entry.name),
                    "database": entry.database.map(JsonValue.string) ?? JsonValue.null,
                    "schema": entry.schema.map(JsonValue.string) ?? JsonValue.null
                ])
            }
        return .structured(.object(["favorites": .array(payload)]))
    }
}

public struct ListRecentTablesTool: MCPToolImplementation {
    public static let name = "list_recent_tables"
    public static let title: String? = String(localized: "List Recent Tables")
    public static let description = String(
        localized: "List the tables the user opened most recently on a connection, newest first."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Recent Tables"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: ["connection_id": MCPToolSchema.connectionId],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "recent_tables": MCPToolSchema.array(
                String(localized: "Recently opened tables, newest first"),
                of: MCPToolSchema.object(
                    properties: [
                        "name": MCPToolSchema.string(String(localized: "Table name")),
                        "database": MCPToolSchema.nullableString(String(localized: "Database it lives in")),
                        "schema": MCPToolSchema.nullableString(String(localized: "Schema it lives in")),
                        "is_view": MCPToolSchema.boolean(String(localized: "Whether the object is a view")),
                        "opened_at": MCPToolSchema.number(String(localized: "Unix epoch seconds"))
                    ],
                    required: ["name", "is_view", "opened_at"]
                )
            )
        ],
        required: ["recent_tables"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        try await MCPToolAuthorization.requireReadAccess(
            connectionId,
            context: context,
            services: services
        )

        let entries = await MainActor.run { RecentTablesStore.shared.entries(connectionId: connectionId) }
        let payload = entries
            .sorted { $0.openedAt > $1.openedAt }
            .map { entry -> JsonValue in
                .object([
                    "name": .string(entry.name),
                    "database": entry.database.map(JsonValue.string) ?? JsonValue.null,
                    "schema": entry.schema.map(JsonValue.string) ?? JsonValue.null,
                    "is_view": .bool(entry.isView),
                    "opened_at": .double(entry.openedAt.timeIntervalSince1970)
                ])
            }
        return .structured(.object(["recent_tables": .array(payload)]))
    }
}
