//
//  DuckDBTransactionProbe.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// How the driver asks DuckDB whether the session has a transaction open, and how the answers are
/// read. No CDuckDB import, so TableProTests can exercise the decision without the plugin bundle.
///
/// DuckDB's C API has no call for this, and the obvious probe is destructive: measured on the
/// shipped v1.5.2, a `BEGIN TRANSACTION` issued inside a transaction does not merely fail, it aborts
/// the transaction it was testing for. `txid_current()` is the one reading that costs nothing.
/// Measured on the same library: outside a transaction two calls answer 6 then 10, inside one they
/// both answer 12, and running it inside an open transaction left the transaction and its rows
/// untouched (`COMMIT` afterwards kept both).
///
/// The catalog gate in front of it is not optional. `txid_current()` is DuckDB's own transaction
/// manager, and the plugin itself moves the session off it: Quack remote mode runs `ATTACH` plus
/// `USE <alias>` at connect, and known-extension autoloading makes `ATTACH ... (TYPE sqlite)`
/// reachable too. Measured against v1.5.2 with a SQLite catalog in front: inside the user's open
/// transaction, `txid_current()` failed with `INTERNAL Error: DuckTransaction::Get called on
/// non-DuckDB transaction` and **took the transaction with it**, so the row the user had inserted
/// was gone after their own `COMMIT` reported success. `duckdb_databases()` is safe in the same
/// place, measured: it answered `sqlite`, and the transaction went on to commit both rows.
enum DuckDBTransactionProbe {
    /// One answer read back from the connection.
    enum Reading: Equatable {
        case value(String)
        /// The statement was refused because the transaction is aborted, which is itself the
        /// answer: `DUCKDB_ERROR_TRANSACTION`, "Current transaction is aborted (please ROLLBACK)".
        case abortedTransaction
        case unreadable
    }

    /// Which transaction manager owns the session's default catalog.
    static let catalogTypeQuery =
        "SELECT type::VARCHAR FROM duckdb_databases() WHERE database_name = current_database()"

    /// Asked twice. A statement outside a transaction gets a transaction of its own, so the two
    /// answers differ; inside one they are the same transaction.
    static let transactionIdQuery = "SELECT txid_current()::VARCHAR"

    /// What the catalog answer settles on its own, or nil when the transaction id has to be probed.
    ///
    /// A catalog DuckDB does not own falls back to what the driver saw go past in the statement
    /// text, which over-reports toward joining: the cost of that is a batch that opens no
    /// transaction of its own, and the cost of the opposite is the user's transaction destroyed.
    static func state(
        catalogType: Reading,
        tracksOpenTransaction: Bool
    ) -> PluginSessionTransactionState? {
        switch catalogType {
        case .abortedTransaction:
            return .abortedTransaction
        case .unreadable:
            return .unknown
        case .value(let type):
            guard type.lowercased() != nativeCatalogType else { return nil }
            return tracksOpenTransaction ? .inTransaction : .idle
        }
    }

    static func state(first: Reading, second: Reading) -> PluginSessionTransactionState {
        if first == .abortedTransaction || second == .abortedTransaction { return .abortedTransaction }
        guard case .value(let firstId) = first, case .value(let secondId) = second else { return .unknown }
        return firstId == secondId ? .inTransaction : .idle
    }

    private static let nativeCatalogType = "duckdb"
}
