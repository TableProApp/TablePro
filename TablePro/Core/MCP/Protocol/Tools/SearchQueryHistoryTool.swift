import Foundation

public struct SearchQueryHistoryTool: MCPToolImplementation {
    public static let name = "search_query_history"
    public static let title: String? = String(localized: "Search Query History")
    public static let description = String(
        localized: """
        Search the query history TablePro keeps on this Mac. Results cover only connections this client \
        may reach, whether or not connection_id is given.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Search Query History"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "query": MCPToolSchema.string(String(localized: "Text matched against the recorded statement")),
            "connection_id": MCPToolSchema.string(String(localized: "Restrict to one connection")),
            "limit": MCPToolSchema.integer(
                String(localized: "Maximum entries to return (1-500, default 50)"),
                minimum: 1,
                maximum: 500
            ),
            "since": MCPToolSchema.number(String(localized: "Earliest executed_at, Unix epoch seconds")),
            "until": MCPToolSchema.number(String(localized: "Latest executed_at, Unix epoch seconds"))
        ],
        required: ["query"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "entries": MCPToolSchema.array(
                String(localized: "Matching history entries, newest first"),
                of: MCPToolSchema.object(
                    properties: [
                        "id": MCPToolSchema.string(String(localized: "Entry id")),
                        "query": MCPToolSchema.string(String(localized: "Statement that ran")),
                        "connection_id": MCPToolSchema.string(String(localized: "Connection it ran on")),
                        "database_name": MCPToolSchema.string(String(localized: "Database it ran against")),
                        "schema_name": MCPToolSchema.string(String(localized: "Schema it ran against")),
                        "database_type": MCPToolSchema.string(String(localized: "Engine")),
                        "source": MCPToolSchema.string(String(localized: "What ran it")),
                        "statement_type": MCPToolSchema.string(String(localized: "Leading keyword class")),
                        "executed_at": MCPToolSchema.number(String(localized: "Unix epoch seconds")),
                        "execution_time_ms": MCPToolSchema.number(String(localized: "Duration in milliseconds")),
                        "row_count": MCPToolSchema.integer(String(localized: "Rows the statement returned")),
                        "was_successful": MCPToolSchema.boolean(String(localized: "Whether it succeeded")),
                        "error_message": MCPToolSchema.string(String(localized: "Redacted failure text"))
                    ],
                    required: [
                        "id", "query", "connection_id", "database_name", "database_type",
                        "source", "statement_type", "executed_at", "execution_time_ms",
                        "row_count", "was_successful"
                    ]
                )
            )
        ],
        required: ["entries"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: ["query", "connection_id", "limit", "since", "until"]
        )
        let query = try MCPArgumentDecoder.requireString(arguments, key: "query")
        let connectionId = try MCPArgumentDecoder.optionalUuid(arguments, key: "connection_id")
        let limit = try MCPArgumentDecoder.optionalInt(arguments, key: "limit", range: 1...500) ?? 50
        let since = try MCPArgumentDecoder.optionalDouble(arguments, key: "since")
            .map { Date(timeIntervalSince1970: $0) }
        let until = try MCPArgumentDecoder.optionalDouble(arguments, key: "until")
            .map { Date(timeIntervalSince1970: $0) }

        if let since, let until, since > until {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "'since' must not be later than 'until'.")
            )
        }

        if let connectionId {
            try await services.authPolicy.resolveAndAuthorize(
                principal: context.principal,
                tool: Self.name,
                connectionId: connectionId,
                sql: nil
            )
        }

        var allowlist = await services.authPolicy.readableConnectionIds(principal: context.principal)
        if let connectionId {
            allowlist = allowlist.intersection([connectionId])
        }
        guard !allowlist.isEmpty else {
            return .structured(.object(["entries": .array([])]))
        }

        let page = await services.queryHistoryManager.fetch(
            QueryHistoryFilter(
                scope: connectionId.map { .connection($0) } ?? .all,
                searchText: query.isEmpty ? nil : query,
                since: since,
                until: until,
                allowedConnectionIds: allowlist
            ),
            limit: limit
        )

        let payload = page.entries.map { entry -> JsonValue in
            var fields: [String: JsonValue] = [
                "id": .string(entry.id.uuidString),
                "query": .string(entry.query),
                "connection_id": .string(entry.connectionId.uuidString),
                "database_name": .string(entry.databaseName),
                "database_type": .string(entry.databaseType.rawValue),
                "source": .string(entry.source.rawValue),
                "statement_type": .string(entry.statementType.rawValue),
                "executed_at": .double(entry.executedAt.timeIntervalSince1970),
                "execution_time_ms": .double(entry.executionTime * 1_000),
                "row_count": .int(entry.rowCount),
                "was_successful": .bool(entry.wasSuccessful)
            ]
            if let schemaName = entry.schemaName {
                fields["schema_name"] = .string(schemaName)
            }
            if let error = entry.errorMessage {
                fields["error_message"] = .string(MCPErrorRedactor.redact(error))
            }
            return .object(fields)
        }

        return .structured(.object(["entries": .array(payload)]))
    }
}
