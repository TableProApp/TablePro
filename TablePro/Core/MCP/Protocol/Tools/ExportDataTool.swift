import Foundation
import os

public struct ExportDataTool: MCPToolImplementation {
    public static let name = "export_data"
    public static let description = String(
        localized: "Export query results or table data to CSV, JSON, or SQL"
    )
    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the connection"))
            ]),
            "format": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Export format: csv, json, or sql")),
                "enum": .array([.string("csv"), .string("json"), .string("sql")])
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string(String(localized: "SQL query to export results from"))
            ]),
            "tables": .object([
                "type": .string("array"),
                "description": .string(String(localized: "Table names to export (alternative to query)")),
                "items": .object(["type": .string("string")])
            ]),
            "output_path": .object([
                "type": .string("string"),
                "description": .string(String(localized: "File path inside the user's Downloads directory (returns inline data if omitted). Paths outside Downloads are rejected."))
            ]),
            "max_rows": .object([
                "type": .string("integer"),
                "description": .string(String(localized: "Maximum rows to export (default 50000)"))
            ])
        ]),
        "required": .array([.string("connection_id"), .string("format")])
    ])
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Export Data"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")
    private static let allowedFormats: Set<String> = ["csv", "json", "sql"]
    private static let exportTableNamePattern = "^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)*$"

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let format = try MCPArgumentDecoder.requireString(arguments, key: "format")
        let query = MCPArgumentDecoder.optionalString(arguments, key: "query")
        let tables = MCPArgumentDecoder.optionalStringArray(arguments, key: "tables")
        let outputPath = MCPArgumentDecoder.optionalString(arguments, key: "output_path")
        let maxRows = MCPArgumentDecoder.optionalInt(
            arguments,
            key: "max_rows",
            default: 50_000,
            clamp: 1...100_000
        ) ?? 50_000

        guard Self.allowedFormats.contains(format) else {
            throw MCPProtocolError.invalidParams(
                detail: "Unsupported format: \(format). Must be csv, json, or sql"
            )
        }

        guard query != nil || tables != nil else {
            throw MCPProtocolError.invalidParams(detail: "Either 'query' or 'tables' must be provided")
        }

        if let tables {
            for table in tables {
                try Self.validateExportTableName(table)
            }
        }

        if let outputPath {
            _ = try Self.sandboxedDownloadsURL(for: outputPath)
        }

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        var queries: [(label: String, sql: String)] = []

        if let query {
            try await services.authPolicy.checkSafeModeDialog(
                sql: query,
                connectionId: connectionId,
                databaseType: meta.databaseType,
                safeModeLevel: meta.safeModeLevel
            )
            queries.append((label: "query", sql: query))
        } else if let tables {
            let quoteIdentifier = Self.identifierQuoter(for: meta.databaseType)
            for table in tables {
                let quoted = try Self.quoteQualifiedIdentifier(table, quoter: quoteIdentifier)
                let sql = "SELECT * FROM \(quoted) LIMIT \(maxRows)"
                try await services.authPolicy.checkSafeModeDialog(
                    sql: sql,
                    connectionId: connectionId,
                    databaseType: meta.databaseType,
                    safeModeLevel: meta.safeModeLevel
                )
                queries.append((label: table, sql: sql))
            }
        }

        var exportResults: [JsonValue] = []
        var totalRowsExported = 0

        for (label, sql) in queries {
            let result = try await services.connectionBridge.executeQuery(
                connectionId: connectionId,
                query: sql,
                maxRows: maxRows,
                timeoutSeconds: 60
            )

            guard let columns = result["columns"]?.arrayValue,
                  let rows = result["rows"]?.arrayValue
            else {
                throw MCPProtocolError.internalError(detail: "Unexpected query result structure")
            }

            let columnNames = columns.compactMap(\.stringValue)
            let formatted: String

            switch format {
            case "csv":
                formatted = Self.formatCSV(columns: columnNames, rows: rows)
            case "json":
                formatted = Self.formatJSON(columns: columnNames, rows: rows)
            case "sql":
                formatted = Self.formatSQL(table: label, columns: columnNames, rows: rows)
            default:
                formatted = Self.formatCSV(columns: columnNames, rows: rows)
            }

            totalRowsExported += rows.count

            exportResults.append(.object([
                "label": .string(label),
                "format": .string(format),
                "row_count": result["row_count"] ?? .int(0),
                "data": .string(formatted)
            ]))
        }

        if let outputPath {
            let fileURL = try Self.sandboxedDownloadsURL(for: outputPath)
            let fullContent: String
            if exportResults.count == 1,
               let data = exportResults.first?["data"]?.stringValue
            {
                fullContent = data
            } else {
                fullContent = exportResults
                    .compactMap { $0["data"]?.stringValue }
                    .joined(separator: "\n\n")
            }
            try fullContent.write(to: fileURL, atomically: true, encoding: .utf8)

            let response: JsonValue = .object([
                "path": .string(fileURL.path),
                "rows_exported": .int(totalRowsExported)
            ])
            return .structured(response)
        }

        let response: JsonValue
        if exportResults.count == 1, let single = exportResults.first {
            response = single
        } else {
            response = .object(["exports": .array(exportResults)])
        }
        return .structured(response)
    }

    static func validateExportTableName(_ table: String) throws {
        guard table.range(of: exportTableNamePattern, options: .regularExpression) != nil else {
            throw MCPProtocolError.invalidParams(
                detail: "Invalid table name: '\(table)'. Allowed characters: letters, digits, underscore, and '.' for schema-qualified names."
            )
        }
    }

    static func identifierQuoter(for databaseType: DatabaseType) -> (String) -> String {
        if let dialect = try? resolveSQLDialect(for: databaseType) {
            return quoteIdentifierFromDialect(dialect)
        }
        return { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    }

    static func quoteQualifiedIdentifier(_ identifier: String, quoter: (String) -> String) throws -> String {
        let segments = identifier.split(separator: ".", omittingEmptySubsequences: true)
        let segmentsWithEmpty = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.count == segmentsWithEmpty.count else {
            throw MCPProtocolError.invalidParams(
                detail: "Invalid qualified identifier: '\(identifier)'. Empty components are not allowed."
            )
        }
        return segments.map { quoter(String($0)) }.joined(separator: ".")
    }

    static func sandboxedDownloadsURL(for path: String) throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw MCPProtocolError.invalidParams(detail: "Downloads directory is not available")
        }
        let downloadsRoot = downloads.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : downloads.appendingPathComponent(path)
        let resolvedPath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = downloadsRoot.hasSuffix("/") ? downloadsRoot : downloadsRoot + "/"
        guard resolvedPath == downloadsRoot || resolvedPath.hasPrefix(prefix) else {
            throw MCPProtocolError.invalidParams(
                detail: "output_path must be inside the Downloads directory (\(downloadsRoot))"
            )
        }
        return URL(fileURLWithPath: resolvedPath)
    }

    static func formatCSV(columns: [String], rows: [JsonValue]) -> String {
        var lines: [String] = []
        lines.append(columns.map { escapeCSVField($0) }.joined(separator: ","))
        for row in rows {
            guard let cells = row.arrayValue else { continue }
            let line = cells.map { cell -> String in
                switch cell {
                case .string(let value):
                    return escapeCSVField(value)
                case .null:
                    return ""
                case .int(let value):
                    return String(value)
                case .double(let value):
                    return String(value)
                case .bool(let value):
                    return value ? "true" : "false"
                default:
                    return escapeCSVField(encodeJSON(cell))
                }
            }
            lines.append(line.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func formatJSON(columns: [String], rows: [JsonValue]) -> String {
        var objects: [JsonValue] = []
        for row in rows {
            guard let cells = row.arrayValue else { continue }
            var dict: [String: JsonValue] = [:]
            for (index, column) in columns.enumerated() where index < cells.count {
                dict[column] = cells[index]
            }
            objects.append(.object(dict))
        }
        return encodeJSON(.array(objects))
    }

    static func formatSQL(table: String, columns: [String], rows: [JsonValue]) -> String {
        guard !columns.isEmpty else { return "" }
        var statements: [String] = []
        let escapedTable = "`\(table.replacingOccurrences(of: "`", with: "``"))`"
        let escapedColumns = columns.map { "`\($0.replacingOccurrences(of: "`", with: "``"))`" }
        let columnList = escapedColumns.joined(separator: ", ")

        for row in rows {
            guard let cells = row.arrayValue else { continue }
            let values = cells.map { cell -> String in
                switch cell {
                case .null:
                    return "NULL"
                case .string(let value):
                    let escaped = value
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    return "'\(escaped)'"
                case .int(let value):
                    return String(value)
                case .double(let value):
                    return String(value)
                case .bool(let value):
                    return value ? "1" : "0"
                default:
                    let escaped = encodeJSON(cell)
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    return "'\(escaped)'"
                }
            }
            statements.append("INSERT INTO \(escapedTable) (\(columnList)) VALUES (\(values.joined(separator: ", ")));")
        }
        return statements.joined(separator: "\n")
    }

    static func encodeJSON(_ value: JsonValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}
