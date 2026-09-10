import Foundation

public struct BrowseTableTool: MCPToolImplementation {
    public static let name = "browse_table"
    public static let title: String? = String(localized: "Browse Table")
    public static let description = String(
        localized: """
        Read rows from a table with filters, sorting and paging, built by TablePro's own query builder \
        for this engine. Prefer it over hand-writing SELECT: it quotes identifiers, escapes values, and \
        pages the way the app does.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Browse Table"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table": MCPToolSchema.table,
            "columns": MCPToolSchema.array(
                String(localized: "Columns to select. Omit for all."),
                of: MCPToolSchema.stringItem
            ),
            "filters": MCPToolSchema.array(
                String(localized: "Filters combined with 'logic'"),
                of: MCPFilterArguments.filterSchema
            ),
            "logic": MCPToolSchema.string(
                String(localized: "How filters combine (default and)"),
                enumValues: ["and", "or"]
            ),
            "sort": MCPToolSchema.array(
                String(localized: "Sort columns in priority order"),
                of: MCPFilterArguments.sortSchema
            ),
            "limit": MCPToolSchema.integer(
                String(localized: "Rows per page. Defaults to the server's configured row limit."),
                minimum: 1
            ),
            "offset": MCPToolSchema.integer(String(localized: "Rows to skip (default 0)"), minimum: 0),
            "timeout_seconds": MCPToolSchema.integer(String(localized: "Statement timeout"), minimum: 1),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "table"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.resultSet

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union([
                "table", "columns", "filters", "logic", "sort", "limit", "offset", "timeout_seconds"
            ])
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let table = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "table")
        let settings = await services.settingsProvider()
        let limit = try MCPLimitResolver.resolveMaxRows(arguments, key: "limit", settings: settings)
        let offset = try MCPArgumentDecoder.optionalInt(arguments, key: "offset", range: 0...100_000_000) ?? 0
        let timeoutSeconds = try MCPLimitResolver.resolveTimeoutSeconds(arguments, settings: settings)
        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        let request = MCPBrowseRequest(
            table: table,
            columns: try MCPArgumentDecoder.optionalStringArray(arguments, key: "columns"),
            filters: try MCPFilterArguments.filters(arguments),
            logicMode: try MCPFilterArguments.logicMode(arguments),
            sort: try MCPFilterArguments.sort(arguments),
            limit: limit,
            offset: offset
        )

        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )

        do {
            let payload = try await services.connectionBridge.browseTable(
                scope: scope,
                request: request,
                timeoutSeconds: timeoutSeconds,
                cancellation: context.cancellation
            )
            return .structured(payload)
        } catch {
            throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
        }
    }
}

public struct CountRowsTool: MCPToolImplementation {
    public static let name = "count_rows"
    public static let title: String? = String(localized: "Count Rows")
    public static let description = String(
        localized: """
        Count rows in a table. Without filters it returns the engine's fast estimate unless 'exact' is set; \
        with filters it always counts for real.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Count Rows"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table": MCPToolSchema.table,
            "exact": MCPToolSchema.boolean(String(localized: "Count every row rather than estimating")),
            "filters": MCPToolSchema.array(
                String(localized: "Filters combined with 'logic'"),
                of: MCPFilterArguments.filterSchema
            ),
            "logic": MCPToolSchema.string(
                String(localized: "How filters combine (default and)"),
                enumValues: ["and", "or"]
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "table"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "table": MCPToolSchema.string(String(localized: "Table that was counted")),
            "row_count": MCPToolSchema.integer(String(localized: "Number of rows")),
            "is_approximate": MCPToolSchema.boolean(String(localized: "Whether the count is an estimate")),
            "filter_count": MCPToolSchema.integer(String(localized: "How many filters were applied"))
        ],
        required: ["table", "row_count", "is_approximate", "filter_count"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["table", "exact", "filters", "logic"])
        )
        let table = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "table")
        let exact = try MCPArgumentDecoder.optionalBool(arguments, key: "exact", default: false)
        let filters = try MCPFilterArguments.filters(arguments)
        let logicMode = try MCPFilterArguments.logicMode(arguments)
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.countRows(
            scope: scope,
            table: table,
            filters: filters,
            logicMode: logicMode,
            exact: exact
        )
        return .structured(payload)
    }
}

public struct QuoteIdentifiersTool: MCPToolImplementation {
    public static let name = "quote_identifiers"
    public static let title: String? = String(localized: "Quote Identifiers")
    public static let description = String(
        localized: """
        Quote identifiers and escape string literals using the connection's own driver rules. Use it \
        before putting any name or value into hand-written SQL.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Quote Identifiers"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "identifiers": MCPToolSchema.array(
                String(localized: "Table or column names to quote"),
                of: MCPToolSchema.stringItem
            ),
            "literals": MCPToolSchema.array(
                String(localized: "String values to escape"),
                of: MCPToolSchema.stringItem
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "identifiers": MCPToolSchema.array(
                String(localized: "Quoted identifiers, in the order supplied"),
                of: MCPToolSchema.object(
                    properties: [
                        "input": MCPToolSchema.string(String(localized: "Name as supplied")),
                        "quoted": MCPToolSchema.string(String(localized: "Name quoted for this engine"))
                    ],
                    required: ["input", "quoted"]
                )
            ),
            "literals": MCPToolSchema.array(
                String(localized: "Escaped literals, in the order supplied"),
                of: MCPToolSchema.object(
                    properties: [
                        "input": MCPToolSchema.string(String(localized: "Value as supplied")),
                        "escaped": MCPToolSchema.string(String(localized: "Value escaped for this engine"))
                    ],
                    required: ["input", "escaped"]
                )
            )
        ],
        required: ["identifiers", "literals"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["identifiers", "literals"])
        )
        let identifiers = try MCPArgumentDecoder.optionalStringArray(arguments, key: "identifiers") ?? []
        let literals = try MCPArgumentDecoder.optionalStringArray(arguments, key: "literals") ?? []
        guard !identifiers.isEmpty || !literals.isEmpty else {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "Pass at least one identifier or literal.")
            )
        }
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.quotingRules(
            scope: scope,
            identifiers: identifiers,
            literals: literals
        )
        return .structured(payload)
    }
}

public struct InsertRowsTool: MCPToolImplementation {
    public static let name = "insert_rows"
    public static let title: String? = String(localized: "Insert Rows")
    public static let description = String(
        localized: """
        Insert rows into a table using bound parameters, so values are never spliced into SQL text. \
        Needs tools:write and goes through the connection's Safe Mode approval.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Insert Rows"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    static let maximumRows = 1_000

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table": MCPToolSchema.table,
            "columns": MCPToolSchema.array(
                String(localized: "Column names, matching each row's value order"),
                of: MCPToolSchema.stringItem
            ),
            "rows": MCPToolSchema.array(
                String(localized: "Rows to insert, each an array aligned with 'columns'"),
                of: .object(["type": .string("array"), "items": MCPToolSchema.cell])
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "table", "columns", "rows"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "table": MCPToolSchema.string(String(localized: "Table that received the rows")),
            "rows_submitted": MCPToolSchema.integer(String(localized: "Rows sent")),
            "rows_affected": MCPToolSchema.integer(String(localized: "Rows the engine reported inserting"))
        ],
        required: ["table", "rows_submitted", "rows_affected"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["table", "columns", "rows"])
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let table = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "table")
        let columns = try MCPArgumentDecoder.optionalStringArray(arguments, key: "columns") ?? []
        guard !columns.isEmpty else {
            throw MCPToolExecutionError.invalidArgument(String(localized: "Pass at least one column."))
        }

        guard case .array(let rawRows)? = arguments["rows"], !rawRows.isEmpty else {
            throw MCPToolExecutionError.invalidArgument(String(localized: "Pass at least one row."))
        }
        guard rawRows.count <= Self.maximumRows else {
            throw MCPToolExecutionError.invalidArgument(
                String(
                    format: String(localized: "Insert at most %d rows per call."),
                    Self.maximumRows
                )
            )
        }
        var rows: [[JsonValue]] = []
        for row in rawRows {
            guard case .array(let cells) = row, cells.count == columns.count else {
                throw MCPToolExecutionError.invalidArgument(
                    String(localized: "Every row must be an array with one value per column.")
                )
            }
            rows.append(cells)
        }

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        let preview = "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (…)"
        try await MCPStatementGate.authorize(
            sql: preview,
            meta: meta,
            allowsDestructive: false,
            operationLabel: String(
                format: String(localized: "inserting %d row(s)"),
                rows.count
            ),
            context: context,
            services: services
        )

        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )

        do {
            let payload = try await services.connectionBridge.insertRows(
                scope: scope,
                table: table,
                columns: columns,
                rows: rows,
                cancellation: context.cancellation
            )
            return .structured(payload)
        } catch {
            throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
        }
    }
}
