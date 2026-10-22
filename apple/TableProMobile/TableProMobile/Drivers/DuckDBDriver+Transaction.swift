import CDuckDB
import Foundation
import TableProDatabase
import TableProModels

// No C API call answers this. A BEGIN inside a transaction aborts it, and txid_current() on a catalog DuckDB does not
// own destroys it, so the probe reads the catalog type, then txid_current() twice: the ids match only inside a
// transaction. Measured for the Mac driver: Plugins/DuckDBDriverPlugin/DuckDBTransactionProbe.swift.
nonisolated enum DuckDBTransactionProbe {
    nonisolated enum Reading: Equatable, Sendable {
        case value(String)
        // Refused with DUCKDB_ERROR_TRANSACTION, "Current transaction is aborted (please ROLLBACK)".
        case abortedTransaction
        case unreadable
    }

    static let catalogTypeQuery =
        "SELECT type::VARCHAR FROM duckdb_databases() WHERE database_name = current_database()"

    static let transactionIdQuery = "SELECT txid_current()::VARCHAR"

    // Nil when the catalog is DuckDB's own and the transaction id has to be asked.
    static func state(catalogType: Reading) -> DriverTransactionState? {
        switch catalogType {
        case .abortedTransaction:
            return .abortedTransaction
        case .unreadable:
            return .unknown
        case .value(let type):
            // The Mac driver falls back to the statements it saw open a transaction; this one tracks none.
            return type.lowercased() == nativeCatalogType ? nil : .unknown
        }
    }

    static func state(first: Reading, second: Reading) -> DriverTransactionState {
        if first == .abortedTransaction || second == .abortedTransaction { return .abortedTransaction }
        guard case .value(let firstId) = first, case .value(let secondId) = second else { return .unknown }
        return firstId == secondId ? .explicitTransaction : .idle
    }

    private static let nativeCatalogType = "duckdb"
}

nonisolated extension DuckDBDriver {
    func sessionTransactionState() async -> DriverTransactionState {
        await actor.transactionState()
    }
}

extension DuckDBActor {
    // One actor turn for every reading, so no other statement lands between the two transaction ids.
    func transactionState() -> DriverTransactionState {
        guard connection != nil else { return .unknown }
        // A statement would end the open stream inside DuckDB. Its consumer's own work reads the state once it ends.
        guard streamResult == nil else { return .unknown }
        let catalogType = probeReading(DuckDBTransactionProbe.catalogTypeQuery)
        if let decided = DuckDBTransactionProbe.state(catalogType: catalogType) {
            return decided
        }
        return DuckDBTransactionProbe.state(
            first: probeReading(DuckDBTransactionProbe.transactionIdQuery),
            second: probeReading(DuckDBTransactionProbe.transactionIdQuery)
        )
    }

    // duckdb_query is the one path that reports the error type; the message text is no contract.
    private func probeReading(_ sql: String) -> DuckDBTransactionProbe.Reading {
        guard let connection else { return .unreadable }
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(connection, sql, &result) != DuckDBError else {
            return duckdb_result_error_type(&result) == DUCKDB_ERROR_TRANSACTION ? .abortedTransaction : .unreadable
        }
        guard duckdb_column_count(&result) > 0 else { return .unreadable }
        var chunk = duckdb_fetch_chunk(result)
        guard chunk != nil else { return .unreadable }
        defer { duckdb_destroy_data_chunk(&chunk) }
        guard duckdb_data_chunk_get_size(chunk) > 0, let vector = duckdb_data_chunk_get_vector(chunk, 0) else {
            return .unreadable
        }
        let type = duckdb_column_type(&result, 0)
        let column = DuckDBStreamColumn(name: "", typeName: Self.typeName(for: type), type: type, castToText: false)
        guard case .text(let value) = Self.decodeCell(vector: vector, row: 0, column: column, options: .default) else {
            return .unreadable
        }
        return .value(value)
    }
}
