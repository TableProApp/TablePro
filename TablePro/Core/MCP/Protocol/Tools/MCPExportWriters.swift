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

enum MCPCsvWriter {
    static let formulaPrefixes: Set<Character> = ["=", "+", "-", "@"]

    static func write(columns: [String], rows: [JsonValue]) -> String {
        var lines: [String] = [columns.map(field).joined(separator: ",")]
        for row in rows {
            guard let cells = row.arrayValue else { continue }
            lines.append(cells.map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n")
    }

    static func cell(_ value: JsonValue) -> String {
        switch value {
        case .null: return ""
        case .string(let text): return field(text)
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .array, .object: return field(value.jsonString())
        }
    }

    static func field(_ value: String) -> String {
        let neutralised = neutralisingFormula(value)
        let needsQuoting = neutralised.contains(",")
            || neutralised.contains("\"")
            || neutralised.contains("\n")
            || neutralised.contains("\r")
            || neutralised.contains("\t")
            || neutralised != value
        guard needsQuoting else { return neutralised }
        return "\"\(neutralised.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func neutralisingFormula(_ value: String) -> String {
        guard let first = value.first else { return value }
        guard formulaPrefixes.contains(first) || first == "\t" || first == "\r" else { return value }
        return "'" + value
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
        let columnList = columns.map(dialect.quote).joined(separator: ", ")

        var statements: [String] = []
        for row in rows {
            guard let cells = row.arrayValue else { continue }
            let values = cells.map { value in literal(value, dialect: dialect) }
            statements.append(
                "INSERT INTO \(quotedTable) (\(columnList)) VALUES (\(values.joined(separator: ", ")));"
            )
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
