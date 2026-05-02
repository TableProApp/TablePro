import Foundation

public struct SearchQueryHistoryTool: MCPToolImplementation {
    public static let name = "search_query_history"
    public static let description = String(
        localized: "Search saved query history. Returns matching entries with execution time, row count, and outcome."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Search Query History"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Search text (full-text matched against the query column)"))
            ]),
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Restrict to a specific connection (UUID, optional)"))
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string(String(localized: "Maximum number of entries to return (default 50, max 500)"))
            ]),
            "since": .object([
                "type": .string("number"),
                "description": .string(String(localized: "Earliest executed_at to include, Unix epoch seconds (inclusive, optional)"))
            ]),
            "until": .object([
                "type": .string("number"),
                "description": .string(String(localized: "Latest executed_at to include, Unix epoch seconds (inclusive, optional)"))
            ])
        ]),
        "required": .array([.string("query")])
    ])

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let query = try MCPArgumentDecoder.requireString(arguments, key: "query")
        let connectionId = try MCPArgumentDecoder.optionalUuid(arguments, key: "connection_id")
        let limit = MCPArgumentDecoder.optionalInt(arguments, key: "limit", default: 50, clamp: 1...500) ?? 50
        let since = MCPArgumentDecoder.optionalDouble(arguments, key: "since").map { Date(timeIntervalSince1970: $0) }
        let until = MCPArgumentDecoder.optionalDouble(arguments, key: "until").map { Date(timeIntervalSince1970: $0) }

        if let since, let until, since > until {
            throw MCPProtocolError.invalidParams(detail: "'since' must be less than or equal to 'until'")
        }

        let blocked = await MainActor.run { MCPTabSnapshotProvider.blockedExternalConnectionIds() }

        if let connectionId, blocked.contains(connectionId) {
            throw MCPProtocolError.forbidden(reason: "External access is disabled for this connection")
        }

        let allowlist: Set<UUID>?
        if connectionId != nil {
            allowlist = nil
        } else if blocked.isEmpty {
            allowlist = nil
        } else {
            let allConnectionIds = await MainActor.run {
                Set(ConnectionStorage.shared.loadConnections().map(\.id))
            }
            allowlist = allConnectionIds.subtracting(blocked)
        }

        let entries = await QueryHistoryStorage.shared.fetchHistory(
            limit: limit,
            offset: 0,
            connectionId: connectionId,
            searchText: query.isEmpty ? nil : query,
            dateFilter: .all,
            since: since,
            until: until,
            allowedConnectionIds: allowlist
        )

        let payload: [JsonValue] = entries.map { entry in
            var dict: [String: JsonValue] = [
                "id": .string(entry.id.uuidString),
                "query": .string(entry.query),
                "connection_id": .string(entry.connectionId.uuidString),
                "database_name": .string(entry.databaseName),
                "executed_at": .double(entry.executedAt.timeIntervalSince1970),
                "execution_time_ms": .double(entry.executionTime * 1_000),
                "row_count": .int(entry.rowCount),
                "was_successful": .bool(entry.wasSuccessful)
            ]
            if let error = entry.errorMessage {
                dict["error_message"] = .string(error)
            }
            return .object(dict)
        }

        return .structured(.object(["entries": .array(payload)]))
    }
}
