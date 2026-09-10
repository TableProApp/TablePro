//
//  DatabaseFileClassifierTests.swift
//  TableProTests
//
//  The magic bytes were read off files the engines wrote, not off documentation: sqlite3 3.43 and
//  DuckDB 1.5.4, which also produced the Parquet file the negative case uses.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Database file classifier")
struct DatabaseFileClassifierTests {
    private static let sqliteHeader = Array("SQLite format 3\u{0}".utf8)

    private static let candidates: [String: [DatabaseFileSignature]] = [
        "SQLite": [.magic("SQLite format 3\u{0}")],
        "DuckDB": [.magic("DUCK", at: 8).andZeroes(at: 14, count: 6)]
    ]

    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseFileClassifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private func write(_ bytes: [UInt8], named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func sqliteBytes() -> [UInt8] {
        Self.sqliteHeader + [UInt8](repeating: 0, count: 512 - Self.sqliteHeader.count)
    }

    /// The header DuckDB 1.5.4 actually wrote: eight checksum bytes, `DUCK`, then storage version
    /// 64 as a little-endian `uint64`, then the flags.
    private func duckdbBytes() -> [UInt8] {
        let checksum: [UInt8] = [0x8B, 0x88, 0x5D, 0xF0, 0xBA, 0x46, 0x13, 0x98]
        let version: [UInt8] = [0x40, 0, 0, 0, 0, 0, 0, 0]
        return checksum + Array("DUCK".utf8) + version + [UInt8](repeating: 0, count: 64)
    }

    private func parquetBytes() -> [UInt8] {
        Array("PAR1".utf8) + [UInt8](repeating: 0x2A, count: 128) + Array("PAR1".utf8)
    }

    private func classify(_ url: URL) -> DatabaseType? {
        DatabaseFileClassifier.classify(url, candidates: Self.candidates)
    }

    @Test("A SQLite database is identified whatever it is called", arguments: [
        "data.sqlite", "app.sqlite3", "store.bin", "ledger", "notes.csv", "query.sql"
    ])
    func identifiesSQLiteByContents(name: String) throws {
        try withTemporaryDirectory { directory in
            let url = try write(sqliteBytes(), named: name, in: directory)
            #expect(classify(url) == .sqlite)
        }
    }

    @Test("A DuckDB database named .db is identified as DuckDB, not SQLite")
    func identifiesDuckDBUnderABorrowedExtension() throws {
        try withTemporaryDirectory { directory in
            let url = try write(duckdbBytes(), named: "warehouse.db", in: directory)
            #expect(classify(url) == .duckdb)
        }
    }

    /// `duckdb_open` picks the reader for a data format from the extension, so a Parquet file
    /// under any other name is refused with "not a valid DuckDB database file". Recognising one by
    /// its `PAR1` markers would route a file the driver then cannot open. Measured on DuckDB 1.5.4.
    @Test("A Parquet file is left to its extension, because DuckDB cannot open one without it")
    func doesNotClaimParquetByContents() throws {
        try withTemporaryDirectory { directory in
            let renamed = try write(parquetBytes(), named: "export.bin", in: directory)
            let named = try write(parquetBytes(), named: "export.parquet", in: directory)
            #expect(classify(renamed) == nil)
            #expect(classify(named) == nil)
        }
    }

    /// `DUCK` alone is four bytes that ordinary SQL spells at exactly that offset, which is why
    /// the signature also requires the storage version's high bytes to be zero.
    @Test("SQL that happens to spell DUCK at offset 8 is not a DuckDB database", arguments: [
        "SELECT 'DUCK';\n", "SELECT 'DUCK' AS bird FROM flock WHERE id = 1;\n"
    ])
    func doesNotMistakeSQLForDuckDB(sql: String) throws {
        try withTemporaryDirectory { directory in
            let url = try write(Array(sql.utf8), named: "query.sql", in: directory)
            #expect(classify(url) == nil)
        }
    }

    @Test("Text, an empty file and a directory are all unidentified")
    func leavesEverythingElseToTheExtension() throws {
        try withTemporaryDirectory { directory in
            let text = try write(Array("SELECT 1;\n".utf8), named: "query.sql", in: directory)
            let empty = try write([], named: "empty.sqlite", in: directory)
            #expect(classify(text) == nil)
            #expect(classify(empty) == nil)
            #expect(classify(directory) == nil)
        }
    }

    @Test("A file shorter than the signature it would match is unidentified")
    func rejectsATruncatedHeader() throws {
        try withTemporaryDirectory { directory in
            let url = try write(Array("SQLite fo".utf8), named: "truncated.sqlite", in: directory)
            #expect(classify(url) == nil)
        }
    }

    @Test("A file that does not exist is unidentified rather than an error")
    func missingFileIsUnidentified() {
        #expect(classify(URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).sqlite")) == nil)
    }

    @Test("A remote URL is never read")
    func remoteURLIsUnidentified() throws {
        let url = try #require(URL(string: "https://example.com/data.sqlite"))
        #expect(classify(url) == nil)
    }

    @Test("With nothing declaring a signature, no file is identified")
    func noCandidatesIdentifiesNothing() throws {
        try withTemporaryDirectory { directory in
            let url = try write(sqliteBytes(), named: "data.sqlite", in: directory)
            #expect(DatabaseFileClassifier.classify(url, candidates: [:]) == nil)
        }
    }

    @Test("SQLite and DuckDB are what the registry actually declares")
    func registryDeclaresTheShippedSignatures() {
        let signatures = PluginMetadataRegistry.shared.allFileSignatures()
        #expect(signatures["SQLite"] == [.magic("SQLite format 3\u{0}")])
        #expect(signatures["DuckDB"] == [.magic("DUCK", at: 8).andZeroes(at: 14, count: 6)])
    }
}
