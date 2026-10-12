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

enum MCPExportValue: Equatable, Sendable {
    case null
    case text(String)
    case number(String)
    case boolean(String)
    case binary(Data)

    init(cell: PluginCellValue, columnType: ColumnType?, family: SQLTypeFamily) {
        self.init(cell: cell, reading: ColumnReading(columnType: columnType, family: family))
    }

    private init(cell: PluginCellValue, reading: ColumnReading) {
        switch cell {
        case .null:
            self = .null
        case .bytes(let data):
            self = .binary(data)
        case .text(let text):
            self = reading.value(of: text)
        }
    }

    static func rows(of result: QueryResult, limit: Int, family: SQLTypeFamily) -> [[MCPExportValue]] {
        let readings = result.columnTypes.map { ColumnReading(columnType: $0, family: family) }
        return result.rows.prefix(limit).map { row in
            row.enumerated().map { index, cell in
                MCPExportValue(cell: cell, reading: readings.indices.contains(index) ? readings[index] : .text)
            }
        }
    }

    static func numberLiteral(of text: String) -> String? {
        JsonNumberNormalizer.numberLiteral(from: text)
    }

    static func booleanValue(of text: String) -> Bool? {
        ColumnTypeSQLQuoting.booleanSynonym(for: text).map { $0 == .isTrue }
    }
}

private extension MCPExportValue {
    enum ColumnReading {
        case text
        case number
        case boolean

        private static let familiesRenderingBitsAsDecimal: Set<SQLTypeFamily> = [.mysql]

        init(columnType: ColumnType?, family: SQLTypeFamily) {
            switch columnType {
            case .integer?, .decimal?:
                self = .number
            case .boolean(let rawType)?:
                self = Self.booleanColumnReading(rawType: rawType, family: family)
            default:
                self = .text
            }
        }

        private static func booleanColumnReading(rawType: String?, family: SQLTypeFamily) -> ColumnReading {
            guard let rawType, case .bitString = SQLTypeParser.parse(rawType, family: family).kind else { return .boolean }
            return familiesRenderingBitsAsDecimal.contains(family) ? .number : .text
        }

        func value(of text: String) -> MCPExportValue {
            switch self {
            case .text:
                return .text(text)
            case .number:
                return MCPExportValue.numberLiteral(of: text) == nil ? .text(text) : .number(text)
            case .boolean:
                if MCPExportValue.booleanValue(of: text) != nil { return .boolean(text) }
                return MCPExportValue.numberLiteral(of: text) == nil ? .text(text) : .number(text)
            }
        }
    }
}

struct MCPSqlExportDialect: Sendable {
    let identifierQuote: String
    let booleanStyle: SQLDialectDescriptor.BooleanLiteralStyle
    let usesBackslashEscaping: Bool
    let binaryStyle: CompareSQLLiteral.BinaryStyle

    static func resolve(for databaseType: DatabaseType) -> MCPSqlExportDialect? {
        guard let dialect = try? resolveSQLDialect(for: databaseType) else { return nil }
        return MCPSqlExportDialect(
            identifierQuote: dialect.identifierQuote,
            booleanStyle: dialect.booleanLiteralStyle,
            usesBackslashEscaping: dialect.requiresBackslashEscaping,
            binaryStyle: CompareSQLLiteral.binaryStyle(for: databaseType)
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

    func binary(_ data: Data) -> String {
        let hex = data.hexEncoded
        switch binaryStyle {
        case .postgresBytea:
            return "decode('\(hex)', 'hex')"
        case .zeroX:
            return "0x\(hex)"
        case .hexToRaw:
            return data.isEmpty ? "EMPTY_BLOB()" : "HEXTORAW('\(hex)')"
        case .unhexFunction:
            return "unhex('\(hex)')"
        case .bitString, .unknown:
            return "X'\(hex)'"
        }
    }
}

/// Escaping and quoting live in `PluginRowWriters`, so a tool result and an exported file spell a
/// value the same way. Only the mapping from `JsonValue` to text is MCP's own.
enum MCPCsvWriter {
    static let options = PluginCsvWriteOptions.toolResult

    static func write(columns: [String], rows: [[MCPExportValue]]) -> String {
        var lines: [String] = [PluginRowWriters.csvLine(columns, options: options)]
        for cells in rows {
            lines.append(PluginRowWriters.csvLine(cells.map(text), options: options))
        }
        return lines.joined(separator: options.lineEnding)
    }

    static func cell(_ value: MCPExportValue) -> String {
        PluginRowWriters.csvField(text(value), options: options)
    }

    static func field(_ value: String) -> String {
        PluginRowWriters.csvField(value, options: options)
    }

    /// A null is an empty cell rather than the word `null`, which is what a spreadsheet expects and
    /// what every reader round-trips back to nothing.
    private static func text(_ value: MCPExportValue) -> String {
        switch value {
        case .null: return ""
        case .text(let text), .number(let text), .boolean(let text): return text
        case .binary(let data): return data.base64EncodedString()
        }
    }
}

enum MCPJsonExportWriter {
    static func write(columns: [String], rows: [[MCPExportValue]]) -> String {
        let keys = columns.map(quoted)
        let objects = rows.map { cells in
            let members = zip(keys, cells).map { key, value in "\(key):\(literal(value))" }
            return "{\(members.joined(separator: ","))}"
        }
        return "[\(objects.joined(separator: ","))]"
    }

    static func literal(_ value: MCPExportValue) -> String {
        switch value {
        case .null: return "null"
        case .text(let text): return quoted(text)
        case .number(let text):
            return MCPExportValue.numberLiteral(of: text) ?? quoted(text)
        case .boolean(let text):
            return MCPExportValue.booleanValue(of: text).map { $0 ? "true" : "false" } ?? quoted(text)
        case .binary(let data): return quoted(data.base64EncodedString())
        }
    }

    private static func quoted(_ text: String) -> String {
        "\"\(PluginExportUtilities.escapeJSONString(text))\""
    }
}

enum MCPSqlExportWriter {
    static func write(
        table: String,
        columns: [String],
        rows: [[MCPExportValue]],
        dialect: MCPSqlExportDialect
    ) -> String {
        guard !columns.isEmpty else { return "" }
        let quotedTable = table
            .split(separator: ".", omittingEmptySubsequences: true)
            .map { dialect.quote(String($0)) }
            .joined(separator: ".")

        let quotedColumns = columns.map(dialect.quote)
        var statements: [String] = []
        for cells in rows {
            let values = cells.map { value in literal(value, dialect: dialect) }
            guard let statement = PluginRowWriters.sqlInsert(
                table: quotedTable, columns: quotedColumns, values: values) else { continue }
            statements.append(statement)
        }
        return statements.joined(separator: "\n")
    }

    static func literal(_ value: MCPExportValue, dialect: MCPSqlExportDialect) -> String {
        switch value {
        case .null: return "NULL"
        case .text(let text): return dialect.literal(text)
        case .number(let text):
            return MCPExportValue.numberLiteral(of: text) ?? dialect.literal(text)
        case .boolean(let text):
            return MCPExportValue.booleanValue(of: text).map(dialect.boolean) ?? dialect.literal(text)
        case .binary(let data): return dialect.binary(data)
        }
    }
}
