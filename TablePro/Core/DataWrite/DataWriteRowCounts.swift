//
//  DataWriteRowCounts.swift
//  TablePro
//

import Foundation

/// Whether a statement's reported row count means what it says on a given engine.
///
/// A keyless save is only held to the count it expected where the count is real. Most drivers read
/// one from the server, but a driver that reports a constant would fail every such save, so an
/// engine has to earn its way onto this list by a driver that actually asks: MySQL's
/// `mysql_affected_rows`, libpq's `PQcmdTuples`, `sqlite3_changes`, db-lib's `dbcount`, and the
/// count `OracleNIO` carries on a finished stream.
enum DataWriteRowCounts {
    private static let enginesReportingRealCounts: Set<DatabaseType> = [
        .mysql, .mariadb, .tidb,
        .postgresql, .redshift, .cockroachdb, .pglite,
        .sqlite, .libsql, .turso, .duckdb,
        .mssql, .oracle,
    ]

    static func areMeaningful(for databaseType: DatabaseType) -> Bool {
        enginesReportingRealCounts.contains(databaseType)
    }
}
