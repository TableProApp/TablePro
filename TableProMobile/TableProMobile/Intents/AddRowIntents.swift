import AppIntents
import Foundation
import TableProModels
import UniformTypeIdentifiers

nonisolated protocol RowInsertingIntent: AppIntent {
    var connection: ConnectionEntity { get }
    var database: DatabaseEntity? { get }
    var table: TableEntity { get }
}

nonisolated extension RowInsertingIntent {
    func insert(rows: [PayloadRow]) async throws -> Int {
        guard let savedConnection = IntentConnectionLoader.connection(id: connection.id) else {
            throw IntentDataError.connectionNotFound
        }
        switch savedConnection.safeModeLevel.writePermission {
        case .blocked:
            throw IntentDataError.readOnly(savedConnection.name.isEmpty ? savedConnection.host : savedConnection.name)
        case .requiresConfirmation:
            let dialog: IntentDialog
            if rows.count == 1 {
                dialog = "Add one row to \(table.name)?"
            } else {
                dialog = "Add \(rows.count) rows to \(table.name)?"
            }
            try await requestConfirmation(
                actionName: .add,
                dialog: dialog
            )
        case .proceed:
            break
        }
        return try await IntentDatabaseSession.with(connection: savedConnection) { session in
            try await session.insertRows(namespace: database?.id, table: table.name, rows: rows)
        }
    }

    func resultDialog(affectedRows: Int) -> IntentDialog {
        if affectedRows == 1 {
            return "Added one row to \(table.name)."
        }
        return "Added \(affectedRows) rows to \(table.name)."
    }
}

struct AddRowToTableIntent: RowInsertingIntent {
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

struct AddRowsToTableIntent: RowInsertingIntent {
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

    @Parameter(title: "File", supportedContentTypes: [.commaSeparatedText, .json, .plainText, .data])
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
