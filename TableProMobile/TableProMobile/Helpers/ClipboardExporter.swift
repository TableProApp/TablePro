import Foundation
import TableProDatabase
import TableProModels
import UIKit
import UniformTypeIdentifiers

nonisolated enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case csv = "CSV"
    case sqlInsert = "SQL INSERT"
    var id: String { rawValue }
}

nonisolated enum ClipboardExporter {
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

    private static func rowToJson(columns: [ColumnInfo], row: [String?]) -> String {
        var pairs: [String] = []
        for (i, col) in columns.enumerated() {
            let value = i < row.count ? row[i] : nil
            let key = "  \"\(escapeJsonString(col.name))\""
            if let value {
                if isJsonNumber(value) {
                    pairs.append("\(key): \(value)")
                } else if value == "true" || value == "false" {
                    pairs.append("\(key): \(value)")
                } else {
                    pairs.append("\(key): \"\(escapeJsonString(value))\"")
                }
            } else {
                pairs.append("\(key): null")
            }
        }
        return "{\n" + pairs.joined(separator: ",\n") + "\n}"
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
            return "'\(escapeLiteral(value, databaseType: databaseType, driver: driver))'"
        }.joined(separator: ", ")
        return "INSERT INTO \(quotedTable) (\(cols)) VALUES (\(vals));"
    }

    private static func escapeLiteral(
        _ value: String,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?
    ) -> String {
        if let driver { return driver.escapeStringLiteral(value) }
        switch databaseType {
        case .mysql, .mariadb:
            return SQLEscaping.backslashStringLiteral(value)
        default:
            return SQLEscaping.ansiStringLiteral(value)
        }
    }

    private static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        if value.isEmpty || value == "NULL" { return "\"\(value)\"" }
        return escapeCsvField(value)
    }

    /// The JSON number grammar over ASCII digits only, so a VARCHAR like "01234", "+5", "0x10" or
    /// "\u{0661}\u{0662}\u{0663}" stays a quoted string rather than a token no JSON parser accepts.
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
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func escapeJsonString(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
           .replacingOccurrences(of: "\r", with: "\\r")
           .replacingOccurrences(of: "\t", with: "\\t")
    }
}
