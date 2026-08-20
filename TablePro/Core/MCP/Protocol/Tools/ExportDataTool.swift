import Foundation
import os
import TableProPluginKit

public struct ExportDataTool: MCPToolImplementation {
    public static let name = "export_data"
    public static let title: String? = String(localized: "Export Data")
    public static let description = String(
        localized: """
        Export the result of a query, or whole tables, as CSV, JSON, or SQL INSERT statements. \
        With output_path the file is written inside the user's Downloads folder and never overwrites an \
        existing file; without it the text comes back inline. SQL output uses the connection's own \
        quoting and literal rules, so exporting a query needs 'sql_table' to name the target table.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Export Data"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "format": MCPToolSchema.string(
                String(localized: "Output format"),
                enumValues: MCPExportFormat.allCases.map(\.rawValue)
            ),
            "query": MCPToolSchema.string(String(localized: "A SELECT to export. Use instead of 'tables'.")),
            "tables": MCPToolSchema.array(
                String(localized: "Tables to export. Use instead of 'query'."),
                of: MCPToolSchema.stringItem
            ),
            "sql_table": MCPToolSchema.string(
                String(localized: "Target table for SQL output when exporting a query")
            ),
            "output_path": MCPToolSchema.string(
                String(localized: "File name or path inside Downloads. Omit to get the text inline.")
            ),
            "max_rows": MCPToolSchema.integer(
                String(localized: "Maximum rows per export. Defaults to the server's configured row limit."),
                minimum: 1
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "format"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "format": MCPToolSchema.string(String(localized: "Format that was produced")),
            "rows_exported": MCPToolSchema.integer(String(localized: "Total rows written")),
            "is_truncated": MCPToolSchema.boolean(String(localized: "Whether the row limit clipped any export")),
            "path": MCPToolSchema.string(String(localized: "File that was written, when output_path was given")),
            "exports": MCPToolSchema.array(
                String(localized: "One entry per query or table"),
                of: MCPToolSchema.object(
                    properties: [
                        "label": MCPToolSchema.string(String(localized: "Table name, or 'query'")),
                        "row_count": MCPToolSchema.integer(String(localized: "Rows in this export")),
                        "is_truncated": MCPToolSchema.boolean(String(localized: "Whether this export was clipped")),
                        "data": MCPToolSchema.string(
                            String(localized: "Exported text. Omitted when the export was written to a file.")
                        )
                    ],
                    required: ["label", "row_count", "is_truncated"]
                )
            )
        ],
        required: ["format", "rows_exported", "is_truncated", "exports"]
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")
    static let tableNamePattern = "^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)*$"

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union([
                "format", "query", "tables", "sql_table", "output_path", "max_rows"
            ])
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let rawFormat = try MCPArgumentDecoder.requireEnum(
            arguments,
            key: "format",
            allowed: MCPExportFormat.allCases.map(\.rawValue)
        )
        guard let format = MCPExportFormat(rawValue: rawFormat) else {
            throw MCPToolExecutionError.invalidArgument(String(localized: "Unsupported export format."))
        }

        let query = try MCPArgumentDecoder.optionalString(arguments, key: "query")
        let tables = try MCPArgumentDecoder.optionalStringArray(arguments, key: "tables")
        let sqlTable = try MCPArgumentDecoder.optionalString(arguments, key: "sql_table")
        let outputPath = try MCPArgumentDecoder.optionalString(arguments, key: "output_path")

        guard query != nil || tables != nil else {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "Pass either 'query' or 'tables'.")
            )
        }
        guard query == nil || tables == nil else {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "Pass 'query' or 'tables', not both.")
            )
        }

        let settings = await services.settingsProvider()
        let maxRows = try MCPLimitResolver.resolveMaxRows(arguments, settings: settings)
        let timeoutSeconds = try MCPLimitResolver.resolveTimeoutSeconds(arguments, settings: settings)
        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        var sqlDialect: MCPSqlExportDialect?
        if format == .sql {
            guard let dialect = MCPSqlExportDialect.resolve(for: meta.databaseType) else {
                throw MCPToolExecutionError.unsupported(
                    String(localized: "This engine has no SQL dialect, so it cannot produce SQL output.")
                )
            }
            sqlDialect = dialect
            if query != nil, sqlTable == nil {
                throw MCPToolExecutionError.invalidArgument(
                    String(localized: "Pass 'sql_table' to name the table the INSERT statements target.")
                )
            }
        }
        if let sqlTable {
            try Self.validateTableName(sqlTable)
        }

        let destination = try outputPath.map {
            try MCPExportDestination.resolveDownloadsURL(for: $0, format: format)
        }

        let statements = try await Self.buildStatements(
            query: query,
            tables: tables,
            sqlTable: sqlTable,
            maxRows: maxRows,
            meta: meta
        )

        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )

        var exports: [JsonValue] = []
        var documents: [String] = []
        var totalRows = 0
        var anyTruncated = false

        for statement in statements {
            try await MCPStatementGate.authorize(
                sql: statement.sql,
                meta: meta,
                allowsDestructive: false,
                operationLabel: String(localized: "an export"),
                context: context,
                services: services
            )

            let result = try await ToolQueryExecutor.executeAndLog(
                services: services,
                query: statement.sql,
                scope: scope,
                maxRows: maxRows + 1,
                timeoutSeconds: timeoutSeconds,
                context: context,
                secrets: meta.redactionSecrets
            )

            guard let rawColumns = result["columns"]?.arrayValue,
                  let rawRows = result["rows"]?.arrayValue
            else {
                throw MCPToolExecutionError.queryFailed(
                    String(localized: "The engine returned no result set to export.")
                )
            }

            let columns = rawColumns.compactMap(\.stringValue)
            let rows = Array(rawRows.prefix(maxRows))
            let isTruncated = rawRows.count > maxRows || (result["is_truncated"]?.boolValue ?? false)
            let document = Self.render(
                format: format,
                label: statement.label,
                columns: columns,
                rows: rows,
                dialect: sqlDialect
            )

            totalRows += rows.count
            anyTruncated = anyTruncated || isTruncated
            documents.append(document)

            var entry: [String: JsonValue] = [
                "label": .string(statement.label),
                "row_count": .int(rows.count),
                "is_truncated": .bool(isTruncated)
            ]
            if destination == nil {
                entry["data"] = .string(document)
            }
            exports.append(.object(entry))
        }

        var payload: [String: JsonValue] = [
            "format": .string(format.rawValue),
            "rows_exported": .int(totalRows),
            "is_truncated": .bool(anyTruncated),
            "exports": .array(exports)
        ]

        guard let destination else {
            return .structured(.object(payload))
        }

        try MCPExportDestination.write(documents.joined(separator: "\n\n"), to: destination)
        payload["path"] = .string(destination.path)
        Self.logger.debug("export_data wrote \(destination.lastPathComponent, privacy: .public)")

        return .structured(
            .object(payload),
            attaching: [
                .resourceLink(
                    uri: destination.absoluteString,
                    name: destination.lastPathComponent,
                    description: String(
                        format: String(localized: "%d exported row(s)"),
                        totalRows
                    ),
                    mimeType: format.mimeType
                )
            ]
        )
    }

    struct ExportStatement {
        let label: String
        let sql: String
    }

    static func buildStatements(
        query: String?,
        tables: [String]?,
        sqlTable: String?,
        maxRows: Int,
        meta: ToolConnectionMetadata
    ) async throws -> [ExportStatement] {
        if let query {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPToolExecutionError.invalidArgument(String(localized: "The query is empty."))
            }
            return [ExportStatement(label: sqlTable ?? "query", sql: trimmed)]
        }
        guard let tables, !tables.isEmpty else {
            throw MCPToolExecutionError.invalidArgument(String(localized: "Pass at least one table."))
        }
        let dialect = try? resolveSQLDialect(for: meta.databaseType)
        guard let dialect else {
            throw MCPToolExecutionError.unsupported(
                String(localized: "This engine has no SQL dialect, so tables cannot be selected generically.")
            )
        }
        let quoter = quoteIdentifierFromDialect(dialect)
        return try tables.map { table in
            try validateTableName(table)
            let quoted = table
                .split(separator: ".", omittingEmptySubsequences: true)
                .map { quoter(String($0)) }
                .joined(separator: ".")
            return ExportStatement(
                label: table,
                sql: limitedSelect(from: quoted, limit: maxRows + 1, style: dialect.autoLimitStyle)
            )
        }
    }

    static func limitedSelect(from quotedTable: String, limit: Int, style: AutoLimitStyle) -> String {
        switch style {
        case .top:
            return "SELECT TOP \(limit) * FROM \(quotedTable)"
        case .fetchFirst:
            return "SELECT * FROM \(quotedTable) FETCH FIRST \(limit) ROWS ONLY"
        case .limit:
            return "SELECT * FROM \(quotedTable) LIMIT \(limit)"
        case .none:
            return "SELECT * FROM \(quotedTable)"
        @unknown default:
            return "SELECT * FROM \(quotedTable)"
        }
    }

    static func render(
        format: MCPExportFormat,
        label: String,
        columns: [String],
        rows: [JsonValue],
        dialect: MCPSqlExportDialect?
    ) -> String {
        switch format {
        case .csv:
            return MCPCsvWriter.write(columns: columns, rows: rows)
        case .json:
            return MCPJsonExportWriter.write(columns: columns, rows: rows)
        case .sql:
            guard let dialect else { return "" }
            return MCPSqlExportWriter.write(
                table: label,
                columns: columns,
                rows: rows,
                dialect: dialect
            )
        }
    }

    static func validateTableName(_ table: String) throws {
        guard table.range(of: tableNamePattern, options: .regularExpression) != nil else {
            throw MCPToolExecutionError.invalidArgument(
                String(
                    format: String(
                        localized: "Table name '%@' may only contain letters, digits, underscore, and '.'."
                    ),
                    table
                )
            )
        }
    }
}
