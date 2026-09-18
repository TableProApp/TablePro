//
//  URLClassifierTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("URLClassifier file extension routing", .serialized)
@MainActor
struct URLClassifierTests {
    private func withInspectorState<T>(
        lazy: [String: URL],
        active: [String: any DocumentInspectorPlugin] = [:],
        body: () throws -> T
    ) rethrows -> T {
        let originalLazy = PluginManager.shared.lazyInspectorFileExtensions
        let originalActive = PluginManager.shared.inspectorPlugins
        defer {
            PluginManager.shared.lazyInspectorFileExtensions = originalLazy
            PluginManager.shared.inspectorPlugins = originalActive
        }
        PluginManager.shared.lazyInspectorFileExtensions = lazy
        PluginManager.shared.inspectorPlugins = active
        return try body()
    }

    @Test("CSV routes to openInspectorFile when the extension is registered")
    func routesCSVWhenExtensionRegistered() {
        let csvURL = URL(fileURLWithPath: "/tmp/sample.csv")
        let stubPluginURL = URL(fileURLWithPath: "/tmp/stub.tableplugin")
        let intent = withInspectorState(lazy: ["csv": stubPluginURL]) {
            URLClassifier.classify(csvURL)
        }
        guard case .some(.success(.openInspectorFile(let routed))) = intent else {
            Issue.record("Expected .openInspectorFile, got \(String(describing: intent))")
            return
        }
        #expect(routed == csvURL)
    }

    @Test("CSV falls back to a DuckDB connection when no inspector plugin registers the extension")
    func routesCSVToDuckDBWhenExtensionMissing() {
        let csvURL = URL(fileURLWithPath: "/tmp/sample.csv")
        let intent = withInspectorState(lazy: [:]) {
            URLClassifier.classify(csvURL)
        }
        guard case .some(.success(.openDatabaseFile(let routed, let dbType))) = intent else {
            Issue.record("Expected .openDatabaseFile, got \(String(describing: intent))")
            return
        }
        #expect(routed == csvURL)
        #expect(dbType == .duckdb)
    }

    @Test("Analytics files with no inspector route to DuckDB", arguments: ["parquet", "json", "ndjson"])
    func routesDuckDBFileKinds(ext: String) {
        let fileURL = URL(fileURLWithPath: "/tmp/export.\(ext)")
        let intent = withInspectorState(lazy: [:]) {
            URLClassifier.classify(fileURL)
        }
        guard case .some(.success(.openDatabaseFile(let routed, let dbType))) = intent else {
            Issue.record("Expected .openDatabaseFile, got \(String(describing: intent))")
            return
        }
        #expect(routed == fileURL)
        #expect(dbType == .duckdb)
    }

    @Test("SQL file routes to openSQLFile", arguments: ["sql", "psql", "pgsql", "PSQL"])
    func routesSQLFile(ext: String) {
        let sqlURL = URL(fileURLWithPath: "/tmp/query.\(ext)")
        let intent = URLClassifier.classify(sqlURL)
        guard case .some(.success(.openSQLFile(let routed))) = intent else {
            Issue.record("Expected .openSQLFile, got \(String(describing: intent))")
            return
        }
        #expect(routed == sqlURL)
    }

    @Test("DuckDB file routes to openDatabaseFile with the DuckDB type", arguments: ["duckdb", "ddb"])
    func routesDuckDBFile(ext: String) {
        let fileURL = URL(fileURLWithPath: "/tmp/warehouse.\(ext)")
        let intent = URLClassifier.classify(fileURL)
        guard case .some(.success(.openDatabaseFile(let routed, let dbType))) = intent else {
            Issue.record("Expected .openDatabaseFile, got \(String(describing: intent))")
            return
        }
        #expect(routed == fileURL)
        #expect(dbType == .duckdb)
    }

    @Test("Unknown file extension returns nil")
    func returnsNilForUnknownExtension() {
        let intent = URLClassifier.classify(URL(fileURLWithPath: "/tmp/file.xyz"))
        #expect(intent == nil)
    }

    // MARK: - Contents

    private func withDatabaseFile<T>(
        named name: String,
        bytes: [UInt8],
        body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("URLClassifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return try body(url)
    }

    private var sqliteBytes: [UInt8] {
        let header = Array("SQLite format 3\u{0}".utf8)
        return header + [UInt8](repeating: 0, count: 512 - header.count)
    }

    private var parquetBytes: [UInt8] {
        Array("PAR1".utf8) + [UInt8](repeating: 0x2A, count: 128) + Array("PAR1".utf8)
    }

    @Test("A SQLite database opens by its contents whatever it is named", arguments: [
        "ledger", "store.bin", "notes.csv", "query.sql"
    ])
    func contentsIdentifyASQLiteDatabase(name: String) throws {
        try withDatabaseFile(named: name, bytes: sqliteBytes) { url in
            let intent = withInspectorState(lazy: ["csv": URL(fileURLWithPath: "/tmp/stub.tableplugin")]) {
                URLClassifier.classify(url)
            }
            guard case .some(.success(.openDatabaseFile(let routed, let dbType))) = intent else {
                Issue.record("Expected .openDatabaseFile, got \(String(describing: intent))")
                return
            }
            #expect(routed == url)
            #expect(dbType == .sqlite)
        }
    }

    /// The DuckDB driver picks a data format's reader from the extension, so a Parquet file has
    /// to keep its name to be openable at all. Claiming one by its `PAR1` markers would route a
    /// file that then fails at connect with "not a valid DuckDB database file".
    @Test("A Parquet file under another name is not claimed")
    func parquetIsNotClaimedByContents() throws {
        try withDatabaseFile(named: "export.bin", bytes: parquetBytes) { url in
            #expect(URLClassifier.classify(url) == nil)
        }
    }

    @Test("A Parquet file keeping its extension still routes to DuckDB")
    func parquetRoutesByExtension() throws {
        try withDatabaseFile(named: "export.parquet", bytes: parquetBytes) { url in
            let intent = withInspectorState(lazy: [:]) { URLClassifier.classify(url) }
            guard case .some(.success(.openDatabaseFile(_, let dbType))) = intent else {
                Issue.record("Expected .openDatabaseFile, got \(String(describing: intent))")
                return
            }
            #expect(dbType == .duckdb)
        }
    }

    @Test("A SQL file whose text spells DUCK at offset 8 still opens in the editor")
    func sqlSpellingTheDuckDBMarkerStillRoutesToTheEditor() throws {
        try withDatabaseFile(named: "query.sql", bytes: Array("SELECT 'DUCK';\n".utf8)) { url in
            guard case .some(.success(.openSQLFile(let routed))) = URLClassifier.classify(url) else {
                Issue.record("Expected .openSQLFile")
                return
            }
            #expect(routed == url)
        }
    }

    @Test("Name-only classification never reads the file")
    func classifyByNameAnswersFromTheNameAlone() throws {
        try withDatabaseFile(named: "ledger", bytes: sqliteBytes) { url in
            #expect(URLClassifier.classifyByName(url) == nil)
        }
        try withDatabaseFile(named: "report.sql", bytes: sqliteBytes) { url in
            guard case .some(.success(.openSQLFile)) = URLClassifier.classifyByName(url) else {
                Issue.record("Expected .openSQLFile from the name alone")
                return
            }
        }
    }

    @Test("A file TablePro cannot read is still unrecognised")
    func contentsDoNotRescueAnUnknownBinary() throws {
        try withDatabaseFile(named: "photo.jpeg", bytes: [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) { url in
            #expect(URLClassifier.classify(url) == nil)
        }
    }

    @Test("TablePro's own file types are decided by name, not contents")
    func ownTypesKeepTheirExtensions() throws {
        try withDatabaseFile(named: "shared.tablepro", bytes: sqliteBytes) { url in
            guard case .some(.success(.openConnectionShare)) = URLClassifier.classify(url) else {
                Issue.record("Expected .openConnectionShare")
                return
            }
        }
    }
}
