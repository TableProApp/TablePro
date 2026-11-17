import TableProMSSQLCore
import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
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

    // `columnDetails` is the table's catalog read, which alone says which columns the server fills in itself.
    static func exportRow(
        columns: [ColumnInfo],
        cells: [Cell],
        format: ExportFormat,
        tableName: String? = nil,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?,
        columnDetails: [ColumnInfo] = []
    ) throws(IncompleteValues) -> String {
        let values = try completeValues(columns: columns, rows: [cells])
        return exportRow(
            columns: columns, row: values[0],
            format: format, tableName: tableName, databaseType: databaseType, driver: driver,
            columnDetails: columnDetails
        )
    }

    static func exportRows(
        columns: [ColumnInfo],
        rows: [[Cell]],
        format: ExportFormat,
        tableName: String? = nil,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?,
        columnDetails: [ColumnInfo] = []
    ) throws(IncompleteValues) -> String {
        let values = try completeValues(columns: columns, rows: rows)
        return exportRows(
            columns: columns, rows: values,
            format: format, tableName: tableName, databaseType: databaseType, driver: driver,
            columnDetails: columnDetails
        )
    }

    static func exportRow(
        columns: [ColumnInfo],
        row: [String?],
        format: ExportFormat,
        tableName: String? = nil,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?,
        columnDetails: [ColumnInfo] = []
    ) -> String {
        switch format {
        case .json:
            return rowToJson(columns: columns, row: row)
        case .csv:
            return rowToCsv(columns: columns, row: row, includeHeader: true)
        case .sqlInsert:
            return InsertWriter(
                columns: columns, columnDetails: columnDetails, tableName: tableName ?? "table",
                databaseType: databaseType, driver: driver
            ).statement(for: row)
        }
    }

    static func exportRows(
        columns: [ColumnInfo],
        rows: [[String?]],
        format: ExportFormat,
        tableName: String? = nil,
        databaseType: DatabaseType,
        driver: (any DatabaseDriver)?,
        columnDetails: [ColumnInfo] = []
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
            let writer = InsertWriter(
                columns: columns, columnDetails: columnDetails, tableName: tableName ?? "table",
                databaseType: databaseType, driver: driver
            )
            return rows.map { writer.statement(for: $0) }.joined(separator: "\n")
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

    static func incompleteColumns(columns: [ColumnInfo], rows: [[Cell]]) -> [String] {
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

    // The macOS JSON export's own rule, so a row copied here and a table exported there agree on every value.
    private static func jsonValue(_ value: String, typeName: String) -> String {
        JSONExportPlugin.formatJSONValue(.text(value), columnTypeName: typeName, preserveAsString: false)
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

    // The rules the macOS SQL export writes a row by: a column the server fills in is left out, and a MySQL BIT value goes
    // bare, since a quoted '5' is stored as the byte 53.
    nonisolated private struct InsertWriter {
        let columns: [ColumnInfo]
        let tableName: String
        let databaseType: DatabaseType
        let driver: (any DatabaseDriver)?
        private let written: [Int]
        private let bitColumns: Set<Int>
        private let firstWritableColumn: String?

        init(
            columns: [ColumnInfo],
            columnDetails: [ColumnInfo],
            tableName: String,
            databaseType: DatabaseType,
            driver: (any DatabaseDriver)?
        ) {
            self.columns = columns
            self.tableName = tableName
            self.databaseType = databaseType
            self.driver = driver
            let serverOwned = Set(columnDetails.filter(\.isServerOwned).map(\.name))
            let declaredTypes = Dictionary(columnDetails.map { ($0.name, $0.typeName) }, uniquingKeysWith: { first, _ in first })
            written = columns.indices.filter { !serverOwned.contains(columns[$0].name) }
            let readsBitAsNumber = SQLBuilder.speaksMySQLDialect(databaseType)
            bitColumns = Set(written.filter { index in
                readsBitAsNumber && ClipboardExporter.isBitType(declaredTypes[columns[index].name] ?? columns[index].typeName)
            })
            firstWritableColumn = columnDetails.first { !$0.isServerOwned }?.name
        }

        func statement(for row: [String?]) -> String {
            let quotedTable = SQLBuilder.quoteIdentifier(tableName, for: databaseType)
            let first = firstWritableColumn.map { SQLBuilder.quoteIdentifier($0, for: databaseType) }
            if written.isEmpty, let defaults = AllDefaultsInsert.sql(
                into: quotedTable, databaseTypeId: databaseType.rawValue, firstWritableColumn: first
            ) {
                return "\(defaults);"
            }
            // An engine with no all-defaults spelling gets every column, which at least shows what the row held.
            let written = written.isEmpty ? Array(columns.indices) : written
            let cols = written
                .map { SQLBuilder.quoteIdentifier(columns[$0].name, for: databaseType) }
                .joined(separator: ", ")
            let vals = written.map { index -> String in
                guard index < row.count, let value = row[index] else { return "NULL" }
                if bitColumns.contains(index), ClipboardExporter.isUnsignedInteger(value) { return value }
                if databaseType == .mssql { return MSSQLStringLiteral.quoted(value) }
                return "'\(ClipboardExporter.literalBody(value, databaseType: databaseType, driver: driver))'"
            }.joined(separator: ", ")
            return "INSERT INTO \(quotedTable) (\(cols)) VALUES (\(vals));"
        }
    }

    // StarRocks' BITMAP is not this type.
    static func isBitType(_ typeName: String) -> Bool {
        let upper = typeName.uppercased().trimmingCharacters(in: .whitespaces)
        return upper == "BIT" || upper.hasPrefix("BIT(")
    }

    static func isUnsignedInteger(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    // The copy declares no sql_mode, so a MySQL literal keeps the escapes every MySQL session reads.
    static func literalBody(
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

    private static func escapeCsvField(_ field: String) -> String {
        if field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\""
        }
        return field
    }
}
