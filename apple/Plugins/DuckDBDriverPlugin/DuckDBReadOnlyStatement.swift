//
//  DuckDBReadOnlyStatement.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation
import TableProPluginKit

// Depends on nothing else in the plugin, so TableProMobileTests compiles it against a DuckDB connection of its own.
nonisolated enum DuckDBReadOnlyStatement {
    // Who asked for the read-only mode, which is what a refusal names.
    nonisolated enum Reason: Sendable, Equatable {
        case externalClients
        case safeMode
    }

    nonisolated enum Refusal: Error, PluginDriverError, Equatable {
        case transactionOpen
        case safeModeTransactionOpen
        case beginFailed(String)

        var pluginErrorMessage: String {
            switch self {
            case .transactionOpen:
                String(localized: "This connection has a transaction open. Commit or roll it back in TablePro, then try again.")
            // Read-Only offers no Commit, so the way out is a rollback.
            case .safeModeTransactionOpen:
                String(
                    localized: "Safe Mode is set to Read-Only for this connection, and it has a transaction open. Roll it back, then try again."
                )
            case .beginFailed(let message):
                message
            }
        }
    }

    // An app read marked `readOnly` alone, a catalog read or a dashboard tile, runs as it is.
    static func reason(for context: PluginStatementContext) -> Reason? {
        if context.readOnly, context.origin == .external { return .externalClients }
        if context.enforcesReadOnly { return .safeMode }
        return nil
    }

    // DuckDB refuses every database write inside a read-only transaction. A BEGIN inside the user's own transaction
    // fails and aborts it (measured on v2.0.0), so only a session known to be idle gets one, and the caller reads that
    // state in the same actor turn.
    static func run<T>(
        on connection: duckdb_connection,
        session: PluginSessionTransactionState,
        reason: Reason = .externalClients,
        _ statement: () throws -> T
    ) throws -> T {
        guard session == .idle else {
            throw reason == .safeMode ? Refusal.safeModeTransactionOpen : Refusal.transactionOpen
        }
        if let failure = send("BEGIN TRANSACTION READ ONLY", on: connection) {
            throw Refusal.beginFailed(failure)
        }
        // Fails without harm when the statement itself ended the transaction.
        defer { _ = send("ROLLBACK", on: connection) }
        return try statement()
    }

    private static func send(_ sql: String, on connection: duckdb_connection) -> String? {
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(connection, sql, &result) == DuckDBError else { return nil }
        return duckdb_result_error(&result).map { String(cString: $0) } ?? "DuckDB refused \(sql)"
    }
}
