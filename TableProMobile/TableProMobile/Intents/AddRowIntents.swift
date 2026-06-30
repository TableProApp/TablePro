import AppIntents
import Foundation
import TableProModels
import UniformTypeIdentifiers

struct AddRowToTableIntent: AppIntent {
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
        let count = try await RowInsertRunner.run(
            connectionId: connection.id,
            namespace: database?.id,
            table: table.name,
            rows: rows
        )
        return .result(value: count, dialog: "Added \(count) row to \(table.name).")
    }
}

struct AddRowsToTableIntent: AppIntent {
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
        let count = try await RowInsertRunner.run(
            connectionId: connection.id,
            namespace: database?.id,
            table: table.name,
            rows: rows
        )
        return .result(value: count, dialog: "Added \(count) rows to \(table.name).")
    }
}

enum RowInsertRunner {
    static func run(connectionId: UUID, namespace: String?, table: String, rows: [PayloadRow]) async throws -> Int {
        guard let connection = IntentConnectionLoader.connection(id: connectionId) else {
            throw IntentDataError.connectionNotFound
        }
        if connection.safeModeLevel.writePermission == .blocked {
            throw IntentDataError.readOnly(connection.name.isEmpty ? connection.host : connection.name)
        }
        return try await IntentDatabaseSession.with(connection: connection) { session in
            try await session.insertRows(namespace: namespace, table: table, rows: rows)
        }
    }
}
