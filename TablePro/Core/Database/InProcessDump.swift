//
//  InProcessDump.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Dumping through a statement the engine itself runs, with no subprocess.
///
/// DuckDB's `EXPORT DATABASE` and ClickHouse's `INTO OUTFILE` write the file from inside the
/// connection TablePro already holds. There is no client binary to find, no password to hand over
/// and nothing to supervise, so none of `NativeDumpService` applies: that whole service exists to
/// spawn a process, redirect its streams and reap it.
///
/// The distinction is not cosmetic. An embedded engine has no server to write on the user's behalf
/// and no CLI in the way, so the file lands wherever the process can write, which is the same place
/// the save panel picked.
enum InProcessDump {
    enum Engine: Equatable {
        case duckDB
        case clickHouse
    }

    static func engine(for type: DatabaseType) -> Engine? {
        switch type {
        case .duckdb: return .duckDB
        case .clickhouse: return .clickHouse
        default:
            return nil
        }
    }

    static func supports(_ type: DatabaseType) -> Bool {
        engine(for: type) != nil
    }

    /// What the dump produces. DuckDB writes a directory of files rather than one file, which the
    /// save panel has to be told before it offers a name.
    static func producesDirectory(_ engine: Engine) -> Bool {
        engine == .duckDB
    }

    static func fileExtension(_ engine: Engine) -> String {
        switch engine {
        case .duckDB: return ""
        case .clickHouse: return "sql"
        }
    }

    /// The statement that writes the dump.
    ///
    /// DuckDB's `EXPORT DATABASE` covers schema and data for the whole database in one statement.
    /// ClickHouse has no equivalent, so a table is written with `SELECT ... INTO OUTFILE`, which is
    /// data only: its `SHOW CREATE TABLE` has to be written separately by the caller.
    static func statement(
        engine: Engine,
        destination: URL,
        table: String?,
        escapeLiteral: (String) -> String,
        quoteIdentifier: (String) -> String
    ) -> String? {
        let path = escapeLiteral(destination.path(percentEncoded: false))
        switch engine {
        case .duckDB:
            return "EXPORT DATABASE '\(path)' (FORMAT PARQUET)"
        case .clickHouse:
            guard let table, !table.isEmpty else { return nil }
            return """
                SELECT * FROM \(quoteIdentifier(table))
                INTO OUTFILE '\(path)'
                FORMAT SQLInsert
                """
        }
    }

    /// Whether the statement covers the whole database or one table. DuckDB exports everything,
    /// ClickHouse one table at a time, and the sheet asks for a table only in the second case.
    static func requiresTable(_ engine: Engine) -> Bool {
        engine == .clickHouse
    }
}
