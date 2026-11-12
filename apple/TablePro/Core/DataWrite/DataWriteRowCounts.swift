//
//  DataWriteRowCounts.swift
//  TablePro
//

import Foundation

/// Whether a statement's reported row count is the rows it matched on a given engine, a row that
/// already held the value included.
///
/// A save is only held to the count it expected where the count is real. Most drivers read one
/// from the server, but a driver that reports a constant would fail every such save, so an engine
/// has to earn its way onto this list by a driver that actually asks: MySQL's `mysql_affected_rows`
/// on a session opened with `CLIENT_FOUND_ROWS`, libpq's `PQcmdTuples`, `sqlite3_changes`, db-lib's
/// `dbcount`, and the count `OracleNIO` carries on a finished stream. A driver can also vouch for one
/// statement's count through `PluginRowWrite.expectedRowCount`.
enum DataWriteRowCounts {
    private static let enginesCountingMatchedRows: Set<DatabaseType> = [
        .mysql, .mariadb, .tidb, .oceanbase,
        .postgresql, .redshift, .cockroachdb, .pglite, .kingbasees,
        .sqlite, .libsql, .turso, .duckdb,
        .mssql, .oracle,
    ]

    static func countsMatchedRows(for databaseType: DatabaseType) -> Bool {
        enginesCountingMatchedRows.contains(databaseType)
    }
}
