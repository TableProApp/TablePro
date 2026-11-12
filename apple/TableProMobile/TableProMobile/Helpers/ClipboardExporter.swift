import TableProMSSQLCore
import Foundation
import TableProDatabase
import TableProModels
import TableProSQLQuoting
import TableProTabularIO
import UIKit
import UniformTypeIdentifiers

nonisolated enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case csv = "CSV"
    case sqlInsert = "SQL INSERT"
    var id: String { rawValue }

    // An INSERT statement means nothing to a key or a collection.
    static func offered(for type: DatabaseType) -> [ExportFormat] {
        type.speaksSQL ? allCases : [.json, .csv]
    }
}

nonisolated enum ClipboardExporter {
    nonisolated struct IncompleteValues: LocalizedError, Equatable {
        let columns: [String]

        var errorDescription: String? {
            String(
                format: String(localized: "Binary values and values not loaded in full cannot be exported: %@."),
                ListFormatter.localizedString(byJoining: columns)
            )
        }
    }

    nonisolated struct TooLarge: LocalizedError, Equatable {
        enum Source: Equatable {
            case page
            case queryResult
        }

        var source: Source = .page

        var errorDescription: String? {
            switch source {
            case .page:
                String(localized: "The full values on this page need more memory than this device has free. Choose a smaller page size and try again.")
            case .queryResult:
                String(localized: "The full values in this result need more memory than this device has free. Run a query that returns fewer rows and try again.")
            }
        }
    }

    static func incompleteColumns(columns: [ColumnInfo], cells: [Cell]) -> [String] {
        incompleteColumns(columns: columns, rows: [cells])
    }

    static func exportRow(
        columns: [ColumnInfo],
        cells: [Cell],
        format: ExportFormat,
        tableName: String? = nil,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?
    ) throws(IncompleteValues) -> String {
        let values = try completeValues(columns: columns, rows: [cells])
        return exportRow(
            columns: columns, row: values[0],
            format: format, tableName: tableName, databaseType: databaseType, driver: driver
        )
    }

    static func exportRows(
        columns: [ColumnInfo],
        rows: [[Cell]],
        format: ExportFormat,
        tableName: String? = nil,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?
    ) throws(IncompleteValues) -> String {
        let values = try completeValues(columns: columns, rows: rows)
        return exportRows(
            columns: columns, rows: values,
            format: format, tableName: tableName, databaseType: databaseType, driver: driver
        )
    }

    static func exportRow(
        columns: [ColumnInfo],
        row: [String?],
        format: ExportFormat,
        tableName: String? = nil,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?
    ) -> String {
        switch format {
        case .json:
            return rowToJson(columns: columns, row: row)
        case .csv:
            return rowToCsv(columns: columns, row: row, includeHeader: true)
        case .sqlInsert:
            return rowToInsert(
                columns: columns, row: row, tableName: tableName ?? "table",
                databaseType: databaseType, driver: driver
            )
        }
    }

    static func exportRows(
        columns: [ColumnInfo],
        rows: [[String?]],
        format: ExportFormat,
        tableName: String? = nil,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?
    ) -> String {
        switch format {
        case .json:
            let objects = rows.map { rowToJson(columns: columns, row: $0) }
            return "[\n" + objects.joined(separator: ",\n") + "\n]"
        case .csv:
            let header = columns.map { escapeCsvField($0.name) }.joined(separator: ",")
            let dataLines = rows.map { row in
                columns.indices.map { i in
                    csvField(i < row.count ? row[i] : nil)
                }.joined(separator: ",")
            }
            return ([header] + dataLines).joined(separator: "\n")
        case .sqlInsert:
            let name = tableName ?? "table"
            return rows.map {
                rowToInsert(
                    columns: columns, row: $0, tableName: name,
                    databaseType: databaseType, driver: driver
                )
            }.joined(separator: "\n")
        }
    }

    static let pasteboardExpiry: TimeInterval = 60

    static func pasteboardPayload(_ text: String, now: Date = Date()) -> (items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
        (
            items: [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: now.addingTimeInterval(pasteboardExpiry),
            ]
        )
    }

    static func copyToClipboard(_ text: String) {
        let payload = pasteboardPayload(text)
        UIPasteboard.general.setItems(payload.items, options: payload.options)
    }

    // MARK: - Private

    private static func incompleteColumns(columns: [ColumnInfo], rows: [[Cell]]) -> [String] {
        columns.indices.compactMap { index in
            let isIncomplete = rows.contains { cells in
                guard index < cells.count else { return false }
                switch cells[index] {
                case .null, .text: return false
                case .truncatedText, .binary: return true
                }
            }
            return isIncomplete ? columns[index].name : nil
        }
    }

    private static func completeValues(columns: [ColumnInfo], rows: [[Cell]]) throws(IncompleteValues) -> [[String?]] {
        let incomplete = incompleteColumns(columns: columns, rows: rows)
        guard incomplete.isEmpty else { throw IncompleteValues(columns: incomplete) }
        return rows.map { cells in
            cells.map { cell -> String? in
                if case .text(let value) = cell { return value }
                return nil
            }
        }
    }

    private static func rowToJson(columns: [ColumnInfo], row: [String?]) -> String {
        var pairs: [String] = []
        for (i, col) in columns.enumerated() {
            let value = i < row.count ? row[i] : nil
            let key = "  " + JSONText.stringLiteral(col.name)
            pairs.append("\(key): \(value.map { jsonValue($0, typeName: col.typeName) } ?? "null")")
        }
        return "{\n" + pairs.joined(separator: ",\n") + "\n}"
    }

    // The column's type decides, as in the Mac export: text that reads like a number or `true` stays text. A column with
    // no type, as SQLite reports for an expression, is read by its value.
    private static func jsonValue(_ value: String, typeName: String) -> String {
        if typeName.trimmingCharacters(in: .whitespaces).isEmpty {
            let bare = isJsonNumber(value) || value == "true" || value == "false"
            return bare ? value : JSONText.stringLiteral(value)
        }
        if isBooleanType(typeName), let flag = booleanLiteral(value) {
            return flag
        }
        if isNumberType(typeName), isJsonNumber(value) {
            return value
        }
        return JSONText.stringLiteral(value)
    }

    // PostgreSQL's text format sends `t` or `f`, and SQLite keeps a boolean as 1 or 0.
    private static func booleanLiteral(_ value: String) -> String? {
        switch value.lowercased() {
        case "true", "t", "1": "true"
        case "false", "f", "0": "false"
        default: nil
        }
    }

    // SQL Server documents `bit` as an integer type that holds 1, 0 or NULL.
    private static func isNumberType(_ typeName: String) -> Bool {
        ColumnInfo.isNumericType(typeName: typeName) || unwrappedTypeName(typeName) == "bit"
    }

    private static func isBooleanType(_ typeName: String) -> Bool {
        let base = unwrappedTypeName(typeName)
        return base == "bool" || base == "boolean"
    }

    // ClickHouse wraps the type, as in `Nullable(Bool)`.
    private static func unwrappedTypeName(_ typeName: String) -> String {
        var base = typeName.lowercased().trimmingCharacters(in: .whitespaces)
        while base.hasSuffix(")"), let open = base.firstIndex(of: "("),
              ["nullable", "lowcardinality"].contains(String(base[..<open])) {
            base = String(base[base.index(after: open) ..< base.index(before: base.endIndex)])
        }
        return base
    }

    private static func rowToCsv(columns: [ColumnInfo], row: [String?], includeHeader: Bool) -> String {
        var lines: [String] = []
        if includeHeader {
            lines.append(columns.map { escapeCsvField($0.name) }.joined(separator: ","))
        }
        let dataLine = columns.indices.map { i in
            csvField(i < row.count ? row[i] : nil)
        }.joined(separator: ",")
        lines.append(dataLine)
        return lines.joined(separator: "\n")
    }

    private static func rowToInsert(
        columns: [ColumnInfo],
        row: [String?],
        tableName: String,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?
    ) -> String {
        let quotedTable = SQLBuilder.quoteIdentifier(tableName, for: databaseType)
        let cols = columns
            .map { SQLBuilder.quoteIdentifier($0.name, for: databaseType) }
            .joined(separator: ", ")
        let vals = columns.indices.map { i in
            let value = i < row.count ? row[i] : nil
            guard let value else { return "NULL" }
            if databaseType == .mssql { return MSSQLStringLiteral.quoted(value) }
            return "'\(escapeLiteral(value, databaseType: databaseType, driver: driver))'"
        }.joined(separator: ", ")
        return "INSERT INTO \(quotedTable) (\(cols)) VALUES (\(vals));"
    }

    private static func escapeLiteral(
        _ value: String,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?
    ) -> String {
        if SQLBuilder.speaksMySQLDialect(databaseType) {
            let escapes = MySQLDriver.keptTextEscapes(for: databaseType, banner: driver?.serverVersion)
            return SQLQuoting.stringLiteralBody(value, escapes: escapes)
        }
        if let driver { return driver.escapeStringLiteral(value) }
        return SQLEscaping.ansiStringLiteral(value)
    }

    private static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        if value.isEmpty || value == "NULL" { return "\"\(value)\"" }
        return escapeCsvField(value)
    }

    // ASCII digits only, so "01234", "+5" or Arabic-Indic digits stay quoted strings.
    private static func isJsonNumber(_ value: String) -> Bool {
        var characters = Substring(value)
        if characters.first == "-" { characters = characters.dropFirst() }
        guard let first = characters.first, isAsciiDigit(first) else { return false }
        if first == "0", characters.count > 1, characters.dropFirst().first.map(isAsciiDigit) == true {
            return false
        }

        var sawDigit = false
        var index = characters.startIndex
        while index < characters.endIndex, isAsciiDigit(characters[index]) {
            sawDigit = true
            index = characters.index(after: index)
        }
        guard sawDigit else { return false }

        if index < characters.endIndex, characters[index] == "." {
            index = characters.index(after: index)
            var sawFraction = false
            while index < characters.endIndex, isAsciiDigit(characters[index]) {
                sawFraction = true
                index = characters.index(after: index)
            }
            guard sawFraction else { return false }
        }

        if index < characters.endIndex, characters[index] == "e" || characters[index] == "E" {
            index = characters.index(after: index)
            if index < characters.endIndex, characters[index] == "+" || characters[index] == "-" {
                index = characters.index(after: index)
            }
            var sawExponent = false
            while index < characters.endIndex, isAsciiDigit(characters[index]) {
                sawExponent = true
                index = characters.index(after: index)
            }
            guard sawExponent else { return false }
        }

        return index == characters.endIndex
    }

    private static func isAsciiDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func escapeCsvField(_ field: String) -> String {
        if field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\""
        }
        return field
    }
}
