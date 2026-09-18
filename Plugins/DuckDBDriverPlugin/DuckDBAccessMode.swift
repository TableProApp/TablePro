//
//  DuckDBAccessMode.swift
//  DuckDBDriverPlugin
//
//  Which access mode a connection opens its file with. No CDuckDB import, so TableProTests
//  can exercise the gate without loading the plugin bundle.
//

import Foundation

/// The value DuckDB's `access_mode` configuration option takes.
///
/// The spelling is load-bearing. Measured against the shipped v1.5.2, `duckdb_set_config`
/// accepts `READ_ONLY` and `read_only` and rejects `READONLY`, `ReadOnly` and anything else with
/// `DuckDBError` -- and a rejected value leaves the config untouched, so the open then **succeeds
/// read-write with writes allowed**. A caller that ignores `duckdb_set_config`'s return therefore
/// ships a read-only toggle that silently does nothing.
enum DuckDBAccessMode: String {
    case readWrite = "READ_WRITE"
    case readOnly = "READ_ONLY"

    static let configurationOption = "access_mode"
}

extension DuckDBAccessMode {
    static let fieldId = "duckdbReadOnly"

    /// Read-only applies to DuckDB's own storage and nothing else. Measured: `access_mode` of
    /// `READ_ONLY` against `:memory:`, or against the Parquet, CSV and JSON readers that
    /// `DuckDBFileKinds.readOnlyData` covers, fails the open outright with
    /// `Catalog Error: Cannot launch in-memory database in read-only mode!`. Those paths hold no
    /// write lock to give up in the first place, and DuckDB never writes back to them, so the
    /// setting is ignored for them rather than turned into a connection that will not open.
    static func resolve(fields: [String: String], path: String) -> DuckDBAccessMode {
        guard fields[fieldId] == "true", carriesAccessMode(path: path) else { return .readWrite }
        return .readOnly
    }

    static func carriesAccessMode(path: String) -> Bool {
        DuckDBFileKinds.database.contains((path as NSString).pathExtension.lowercased())
    }
}
