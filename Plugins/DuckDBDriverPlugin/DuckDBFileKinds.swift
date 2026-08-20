//
//  DuckDBFileKinds.swift
//  DuckDBDriverPlugin
//
//  The file kinds a DuckDB connection can open, split by whether opening one can
//  create it. Extracted so the connection form's Browse panel and the driver's own
//  path handling read the same list, and so both can be tested without the bundle.
//

import Foundation

enum DuckDBFileKinds {
    /// DuckDB's own storage format. Opening a path that does not exist creates the
    /// database there, which is what the connection form's file field offers.
    static let database = ["duckdb", "ddb"]

    /// DuckDB 1.5 opens these as a database too: it starts an in-memory catalog and
    /// creates two read-only views over the file, `file` and the file stem. Nothing is
    /// written back, and the file on disk is left byte for byte identical.
    static let readOnlyData = ["parquet", "csv", "tsv", "json", "ndjson"]

    /// Database formats lead so the file field's placeholder reads
    /// `/path/to/database.duckdb` rather than naming a format you cannot create.
    static let all = database + readOnlyData

    /// A missing `.duckdb` path is a request to create a database. A missing `.parquet`
    /// or `.csv` path is a typo, and DuckDB would answer it by creating an empty database
    /// under that name, which reads as a working connection to nothing.
    static func canBeCreated(atPath path: String) -> Bool {
        !readOnlyData.contains((path as NSString).pathExtension.lowercased())
    }
}
