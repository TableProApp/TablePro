import Foundation
import TableProMCP

public struct SearchQueryHistoryTool: MCPToolImplementation {
    public static let name = "search_query_history"
    public static let title: String? = String(localized: "Search Query History")
    public static let description = String(
        localized: """
        Search the query history TablePro keeps on this Mac. With connection_id, TablePro asks the user about \
        that connection first. Without it, results cover only connections this client may already reach \
        without asking.
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
            "connection_id": MCPToolSchema.string(
                String(localized: "Restrict to one connection. Omit for every connection already approved.")
            ),
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
            ),
            "is_truncated": MCPToolSchema.boolean(
                String(localized: "Whether the size limit left out matching entries")
            )
        ],
        required: ["entries", "is_truncated"]
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

        let allowlist: Set<UUID>
        if let connectionId {
            // ToolsCallHandler already asked about this connection; Ask Every Time records nothing, so asking here asked twice.
            try await MCPToolAuthorization.requireReadAccess(connectionId, context: context, services: services)
            allowlist = [connectionId]
        } else {
            allowlist = await services.authPolicy.connectionIdsReadableWithoutPrompt(principal: context.principal)
        }
        guard !allowlist.isEmpty else {
            return .structured(.object(["entries": .array([]), "is_truncated": .bool(false)]))
        }

        var anyMasksValues = false
        for allowed in allowlist {
            if await !services.connectionBridge.maskingPolicy(for: allowed).isEmpty {
                anyMasksValues = true
                break
            }
        }
        let page = await services.queryHistoryManager.fetch(
            QueryHistoryFilter(
                scope: connectionId.map { .connection($0) } ?? .all,
                sources: MCPConnectionBridge.searchableSources(by: query, masksValues: anyMasksValues),
                searchText: query.isEmpty ? nil : query,
                since: since,
                until: until,
                allowedConnectionIds: allowlist
            ),
            limit: limit
        )

        var masksValues: [UUID: Bool] = [:]
        for entryConnection in Set(page.entries.map(\.connectionId)) {
            masksValues[entryConnection] = await !services.connectionBridge.maskingPolicy(for: entryConnection).isEmpty
        }

        let entries = page.entries.filter {
            MCPConnectionBridge.isSearchable($0, by: query, masksValues: masksValues[$0.connectionId] == true)
        }
        let payload = entries.map { entry -> JsonValue in
            var fields: [String: JsonValue] = [
                "id": .string(entry.id.uuidString),
                "query": .string(
                    MCPConnectionBridge.externalQueryText(of: entry, masksValues: masksValues[entry.connectionId] == true)
                ),
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
                fields["error_message"] = .string(
                    MCPConnectionBridge.externalErrorText(error, masksValues: masksValues[entry.connectionId] == true)
                )
            }
            return .object(fields)
        }

        let answer = MCPConnectionBridge.withinAnswerBudget(payload)
        return .structured(.object([
            "entries": .array(answer.entries),
            "is_truncated": .bool(answer.isTruncated)
        ]))
    }
}
