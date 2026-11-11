import Foundation
import os
import SQLite3
@testable import TablePro
import Testing

struct QueryHistoryStoreRecoveryTests {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("history-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    // The pre-v3 shape, except that database_name allows NULL, which the v3 table refuses.
    private func makeLegacyDatabase(rows: [(query: String, databaseName: String?)], connectionId: UUID) -> URL {
        let url = scratch.appendingPathComponent("query_history.db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK else { return url }
        defer { sqlite3_close_v2(db) }

        sqlite3_exec(db, """
            CREATE TABLE history (
                id TEXT PRIMARY KEY,
                query TEXT NOT NULL,
                connection_id TEXT NOT NULL,
                database_name TEXT,
                executed_at REAL NOT NULL,
                execution_time REAL NOT NULL,
                row_count INTEGER NOT NULL,
                was_successful INTEGER NOT NULL,
                error_message TEXT
            );
            """, nil, nil, nil)
        sqlite3_exec(db, "PRAGMA user_version = 2;", nil, nil, nil)

        for row in rows {
            var statement: OpaquePointer?
            let insert = """
                INSERT INTO history (id, query, connection_id, database_name, executed_at,
                                     execution_time, row_count, was_successful, error_message)
                VALUES (?, ?, ?, ?, 1700000000, 0.5, 1, 1, NULL);
                """
            guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, UUID().uuidString, -1, Self.transient)
            sqlite3_bind_text(statement, 2, row.query, -1, Self.transient)
            sqlite3_bind_text(statement, 3, connectionId.uuidString, -1, Self.transient)
            if let databaseName = row.databaseName {
                sqlite3_bind_text(statement, 4, databaseName, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        return url
    }

    private func scalarInt(in url: URL, _ sql: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @Test("A version 3 migration whose copy fails keeps every legacy row and leaves the store closed")
    func failedMigrationKeepsLegacyRows() async {
        let url = makeLegacyDatabase(
            rows: [(query: "SELECT 1", databaseName: "legacydb"), (query: "SELECT 2", databaseName: nil)],
            connectionId: UUID()
        )
        let storage = QueryHistoryStorage(databaseURL: url)

        #expect(await storage.isStoreAvailable() == false)
        #expect(scalarInt(in: url, "SELECT COUNT(*) FROM history;") == 2)
        #expect(scalarInt(in: url, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'history_legacy';") == 0)
        #expect(scalarInt(in: url, "SELECT COUNT(*) FROM pragma_table_info('history') WHERE name = 'source';") == 0)
        #expect(scalarInt(in: url, "PRAGMA user_version;") == 2)
    }

    @Test("A damaged history database is set aside once and recording works again")
    func damagedStoreIsSetAside() async throws {
        let url = scratch.appendingPathComponent("query_history.db")
        let damaged = Data(repeating: 0x2A, count: 4_096)
        try damaged.write(to: url)
        let reports = OSAllocatedUnfairLock(initialState: [SetAsideDamagedStore]())
        let storage = QueryHistoryStorage(
            databaseURL: url,
            removeDatabaseOnDeinit: true,
            onSetAside: { report in reports.withLock { $0.append(report) } }
        )
        let entry = QueryHistoryEntry(
            query: "SELECT 1",
            connectionId: UUID(),
            databaseName: "app",
            databaseType: .postgresql,
            source: .editor,
            executionTime: 0.1,
            rowCount: 1,
            wasSuccessful: true
        )

        #expect(await storage.record(entry))
        #expect(await storage.isStoreAvailable())
        #expect(await storage.count(scope: .all) == 1)

        let setAside = try #require(reports.withLock { $0 }.first)
        #expect(reports.withLock { $0.count } == 1)
        #expect(setAside.storeURL == url)
        #expect(try Data(contentsOf: setAside.setAsideURL) == damaged)
    }

    @Test("Clearing every row also deletes the damaged copy set aside earlier, and a narrower clear keeps it")
    func fullClearDeletesTheSetAsideCopy() async throws {
        let url = scratch.appendingPathComponent("query_history.db")
        try Data(repeating: 0x2A, count: 4_096).write(to: url)
        let reports = OSAllocatedUnfairLock(initialState: [SetAsideDamagedStore]())
        let storage = QueryHistoryStorage(
            databaseURL: url,
            removeDatabaseOnDeinit: true,
            onSetAside: { report in reports.withLock { $0.append(report) } }
        )
        #expect(await storage.isStoreAvailable())
        let setAsidePath = try #require(reports.withLock { $0 }.first).setAsideURL.path(percentEncoded: false)

        #expect(await storage.clear(matching: QueryHistoryFilter(scope: .all, sources: QueryHistorySource.userAuthored)))
        #expect(FileManager.default.fileExists(atPath: setAsidePath))

        #expect(await storage.clear(matching: QueryHistoryFilter(scope: .all)))
        #expect(!FileManager.default.fileExists(atPath: setAsidePath))
    }
}
