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
        !opensAsReader(path)
    }

    // Measured on the shipped libduckdb (scripts/probes/check-duckdb-access-mode.sh): DuckDB picks a reader by name,
    // in any case and with or without gzip or zstd around it, and opens every other path as a database.
    static func opensAsReader(_ path: String) -> Bool {
        var name = (path as NSString).lastPathComponent.lowercased() as NSString
        if compressionExtensions.contains(name.pathExtension) {
            name = name.deletingPathExtension as NSString
        }
        return readerExtensions.contains(name.pathExtension)
    }

    private static let readerExtensions = Set(readOnlyData + ["jsonl"])

    private static let compressionExtensions: Set<String> = ["gz", "zst"]

    private static let duckDBMagic = Data("DUCK".utf8)
    private static let duckDBMagicOffset = 8
    private static let sqliteMagic = Data("SQLite format 3\u{0}".utf8)

    // DuckDB opens its own storage and a SQLite file by their header, whatever they are called.
    static func holdsDatabase(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: sqliteMagic.count) else { return false }
        if header.starts(with: sqliteMagic) { return true }
        let magicRange = duckDBMagicOffset..<(duckDBMagicOffset + duckDBMagic.count)
        return header.count >= magicRange.upperBound && header.subdata(in: magicRange) == duckDBMagic
    }
}
