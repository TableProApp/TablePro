//
//  RunQueryIntent.swift
//  TablePro
//

import AppIntents
import Foundation

@available(macOS 14.0, *)
internal struct RunQueryIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Query"
    static let description = IntentDescription(
        "Run a SQL statement on a saved connection and pass the result to the next action.",
        categoryName: "Database",
        searchKeywords: ["TablePro", "database", "SQL", "query", "select"]
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(
        title: "Query",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var query: String

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    @Parameter(title: "Database or Schema")
    var database: DatabaseEntity?

    @Parameter(title: "Result", default: .rows)
    var format: QueryResultFormat

    @Parameter(
        title: "Row Limit",
        default: 500,
        controlStyle: .field,
        inclusiveRange: (1, 10_000)
    )
    var rowLimit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$query) on \(\.$connection)") {
            \.$database
            \.$format
            \.$rowLimit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outcome = try await ShortcutsQuery.run(
            sql: query,
            connectionId: connection.id,
            namespace: database?.id,
            rowLimit: rowLimit
        )
        return .result(
            value: QueryResultFiles.files(
                columns: outcome.primary.columns,
                rows: outcome.primary.rows,
                format: format
            )
        )
    }
}

internal enum ShortcutsQuery {
    internal static func run(
        sql: String,
        connectionId: UUID,
        namespace: String?,
        rowLimit: Int?,
        bridge: DatabaseAccessBridge = DatabaseAccessBridge(),
        history: QueryHistoryRecording = QueryHistoryManager.shared,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> DatabaseAccessBridge.ScriptOutcome {
        let placement = await MainActor.run { () -> ShortcutsCatalog.Placement in
            guard let stored = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }) else {
                return ShortcutsCatalog.Placement(database: nil, schema: nil)
            }
            return ShortcutsCatalog.placement(of: namespace, databaseType: stored.type)
        }
        do {
            return try await ScriptQueryRunner.run(
                ScriptQueryRunner.Request(
                    sql: sql,
                    connectionId: connectionId,
                    database: placement.database,
                    schema: placement.schema,
                    rowLimit: rowLimit,
                    timeoutSeconds: nil,
                    channel: .shortcuts
                ),
                bridge: bridge,
                history: history,
                gate: gate
            )
        } catch {
            throw ShortcutsActionError.wrapping(error)
        }
    }
}
