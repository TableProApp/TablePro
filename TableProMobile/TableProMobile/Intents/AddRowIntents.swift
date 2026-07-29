import AppIntents
import Foundation
import TableProModels
import UniformTypeIdentifiers

protocol RowInsertingIntent: AppIntent {
    var connection: ConnectionEntity { get }
    var database: DatabaseEntity? { get }
    var table: TableEntity { get }
}

extension RowInsertingIntent {
    func insert(rows: [PayloadRow]) async throws -> Int {
        guard let savedConnection = IntentConnectionLoader.connection(id: connection.id) else {
            throw IntentDataError.connectionNotFound
        }
        switch savedConnection.safeModeLevel.writePermission {
        case .blocked:
            throw IntentDataError.readOnly(savedConnection.name.isEmpty ? savedConnection.host : savedConnection.name)
        case .requiresConfirmation:
            let noun = rows.count == 1 ? "row" : "rows"
            try await requestConfirmation(
                actionName: .add,
                dialog: "Add \(rows.count) \(noun) to \(table.name)?"
            )
        case .proceed:
            break
        }
        return try await IntentDatabaseSession.with(connection: savedConnection) { session in
            try await session.insertRows(namespace: database?.id, table: table.name, rows: rows)
        }
    }
}

struct AddRowToTableIntent: RowInsertingIntent {
    static var title: LocalizedStringResource = "Add Row to Table"
    static var description = IntentDescription(
        "Add one row to a table on a saved connection. Provide the row as a JSON object or a CSV row."
    )
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

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
        return .result(value: count, dialog: "Added \(count) row to \(table.name).")
    }
}

struct AddRowsToTableIntent: RowInsertingIntent {
    static var title: LocalizedStringResource = "Add Rows to Table"
    static var description = IntentDescription(
        "Add multiple rows to a table on a saved connection. Provide the rows as a JSON array, CSV text, or a file."
    )
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

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
        return .result(value: count, dialog: "Added \(count) rows to \(table.name).")
    }
}
