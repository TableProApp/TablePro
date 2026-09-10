import Foundation
import TableProPluginKit

enum MCPExportFormat: String, Sendable, CaseIterable {
    case csv
    case json
    case sql

    var fileExtension: String { rawValue }

    var mimeType: String {
        switch self {
        case .csv: return "text/csv"
        case .json: return "application/json"
        case .sql: return "application/sql"
        }
    }
}

struct MCPSqlExportDialect: Sendable {
    let identifierQuote: String
    let booleanStyle: SQLDialectDescriptor.BooleanLiteralStyle
    let usesBackslashEscaping: Bool

    static func resolve(for databaseType: DatabaseType) -> MCPSqlExportDialect? {
        guard let dialect = try? resolveSQLDialect(for: databaseType) else { return nil }
        return MCPSqlExportDialect(
            identifierQuote: dialect.identifierQuote,
            booleanStyle: dialect.booleanLiteralStyle,
            usesBackslashEscaping: dialect.requiresBackslashEscaping
        )
    }

    func quote(_ name: String) -> String {
        guard identifierQuote != "[" else {
            return "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
        }
        let escaped = name.replacingOccurrences(
            of: identifierQuote,
            with: identifierQuote + identifierQuote
        )
        return "\(identifierQuote)\(escaped)\(identifierQuote)"
    }

    func literal(_ value: String) -> String {
        guard usesBackslashEscaping else {
            return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    func boolean(_ value: Bool) -> String {
        switch booleanStyle {
        case .truefalse: return value ? "TRUE" : "FALSE"
        case .numeric: return value ? "1" : "0"
        @unknown default: return value ? "TRUE" : "FALSE"
        }
    }
}

/// Escaping and quoting live in `PluginRowWriters`, so a tool result and an exported file spell a
/// value the same way. Only the mapping from `JsonValue` to text is MCP's own.
enum MCPCsvWriter {
    static let options = PluginCsvWriteOptions.toolResult

    static func write(columns: [String], rows: [JsonValue]) -> String {
        var lines: [String] = [PluginRowWriters.csvLine(columns, options: options)]
        for row in rows {
            guard let cells = row.arrayValue else { continue }
            lines.append(PluginRowWriters.csvLine(cells.map(text), options: options))
        }
        return lines.joined(separator: options.lineEnding)
    }

    static func cell(_ value: JsonValue) -> String {
        PluginRowWriters.csvField(text(value), options: options)
    }

    static func field(_ value: String) -> String {
        PluginRowWriters.csvField(value, options: options)
    }

    /// A null is an empty cell rather than the word `null`, which is what a spreadsheet expects and
    /// what every reader round-trips back to nothing.
    private static func text(_ value: JsonValue) -> String {
        switch value {
        case .null: return ""
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .array, .object: return value.jsonString()
        }
    }
}

enum MCPJsonExportWriter {
    static func write(columns: [String], rows: [JsonValue]) -> String {
        var objects: [JsonValue] = []
        for row in rows {
            guard let cells = row.arrayValue else { continue }
            var fields: [String: JsonValue] = [:]
            for (index, column) in columns.enumerated() where index < cells.count {
                fields[column] = cells[index]
            }
            objects.append(.object(fields))
        }
        return JsonValue.array(objects).jsonString()
    }
}

enum MCPSqlExportWriter {
    static func write(
        table: String,
        columns: [String],
        rows: [JsonValue],
        dialect: MCPSqlExportDialect
    ) -> String {
        guard !columns.isEmpty else { return "" }
        let quotedTable = table
            .split(separator: ".", omittingEmptySubsequences: true)
            .map { dialect.quote(String($0)) }
            .joined(separator: ".")

        let quotedColumns = columns.map(dialect.quote)
        var statements: [String] = []
        for row in rows {
            guard let cells = row.arrayValue else { continue }
            let values = cells.map { value in literal(value, dialect: dialect) }
            guard let statement = PluginRowWriters.sqlInsert(
                table: quotedTable, columns: quotedColumns, values: values) else { continue }
            statements.append(statement)
        }
        return statements.joined(separator: "\n")
    }

    static func literal(_ value: JsonValue, dialect: MCPSqlExportDialect) -> String {
        switch value {
        case .null: return "NULL"
        case .string(let text): return dialect.literal(text)
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return dialect.boolean(flag)
        case .array, .object: return dialect.literal(value.jsonString())
        }
    }
}
