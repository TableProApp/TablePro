//
//  AddRowIntents.swift
//  TablePro
//

import AppIntents
import Foundation

@available(macOS 14.0, *)
internal protocol RowInsertingIntent: AppIntent {
    var connection: ConnectionEntity { get }
    var database: DatabaseEntity? { get }
    var table: TableEntity { get }
}

@available(macOS 14.0, *)
extension RowInsertingIntent {
    func insert(rows: [PayloadRow]) async throws -> Int {
        try await ShortcutsRowWriter.insert(
            ShortcutsRowWriter.Request(
                rows: rows,
                table: table.name,
                connectionId: connection.id,
                namespace: database?.id
            )
        )
    }

    func resultDialog(affectedRows: Int) -> IntentDialog {
        if affectedRows == 1 {
            return "Added one row to \(table.name)."
        }
        return "Added \(affectedRows) rows to \(table.name)."
    }
}

@available(macOS 14.0, *)
internal struct AddRowToTableIntent: RowInsertingIntent {
    static let title: LocalizedStringResource = "Add Row to Table"
    static let description = IntentDescription(
        "Add one row to a table on a saved connection. Provide the row as a JSON object or a CSV row.",
        categoryName: "Database",
        searchKeywords: ["TablePro", "database", "SQL", "insert", "row", "table"]
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    @Parameter(title: "Database or Schema")
    var database: DatabaseEntity?

    @Parameter(title: "Table")
    var table: TableEntity

    @Parameter(title: "Row (JSON or CSV)")
    var data: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add a row to \(\.$table)") {
            \.$connection
            \.$database
            \.$data
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let rows = try await RowPayload.parseSingle(data: data, file: nil)
        let count = try await insert(rows: rows)
        return .result(value: count, dialog: resultDialog(affectedRows: count))
    }
}

@available(macOS 14.0, *)
internal struct AddRowsToTableIntent: RowInsertingIntent {
    static let title: LocalizedStringResource = "Add Rows to Table"
    static let description = IntentDescription(
        "Add multiple rows to a table on a saved connection. Provide the rows as a JSON array, CSV text, or a file.",
        categoryName: "Database",
        searchKeywords: ["TablePro", "database", "SQL", "insert", "rows", "table", "import"]
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    @Parameter(title: "Database or Schema")
    var database: DatabaseEntity?

    @Parameter(title: "Table")
    var table: TableEntity

    @Parameter(title: "Rows (JSON or CSV)")
    var data: String?

    // A file type filter needs macOS 15; the payload is read as text whatever the file says it is.
    @Parameter(title: "File")
    var file: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Add rows to \(\.$table)") {
            \.$connection
            \.$database
            \.$data
            \.$file
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let rows = try await RowPayload.parse(data: data, file: file)
        let count = try await insert(rows: rows)
        return .result(value: count, dialog: resultDialog(affectedRows: count))
    }
}
