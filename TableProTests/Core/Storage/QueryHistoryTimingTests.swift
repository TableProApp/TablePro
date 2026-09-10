//
//  QueryHistoryTimingTests.swift
//  TableProTests
//
//  The split between execution and transfer, from the column that stores it to the ranking
//  that reads it.
//

import Foundation
import SQLite3
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("QueryHistory timing")
struct QueryHistoryTimingTests {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func makeStorage() -> QueryHistoryStorage {
        QueryHistoryStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("query_timing_\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
    }

    private func record(
        _ storage: QueryHistoryStorage,
        _ query: String,
        connectionId: UUID,
        executionTime: TimeInterval,
        firstRowTime: TimeInterval? = nil,
        serverTime: TimeInterval? = nil
    ) async {
        _ = await storage.record(QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "testdb",
            databaseType: .postgresql,
            source: .editor,
            executionTime: executionTime,
            rowCount: 1,
            wasSuccessful: true,
            firstRowTime: firstRowTime,
            serverTime: serverTime
        ))
    }

    // MARK: - Round trip

    @Test("Both figures survive a write and a read")
    func splitRoundTrips() async {
        let storage = makeStorage()
        let connectionId = UUID()
        await record(storage, "SELECT 1", connectionId: connectionId,
                     executionTime: 3.4, firstRowTime: 0.012, serverTime: 0.009)

        let entries = await storage.fetch(
            QueryHistoryFilter(scope: .connection(connectionId)), after: nil, limit: 10
        ).entries

        #expect(entries.count == 1)
        #expect(entries.first?.firstRowTime == 0.012)
        #expect(entries.first?.serverTime == 0.009)
        #expect(entries.first?.databaseTime == 0.009)
    }

    /// The columns are nullable and `sqlite3_column_double` reads a NULL back as 0.0, which would
    /// render as a query that took no time rather than one nothing measured.
    @Test("An unmeasured row reads back as absent, not as zero")
    func unmeasuredReadsBackAsNil() async {
        let storage = makeStorage()
        let connectionId = UUID()
        await record(storage, "SELECT 2", connectionId: connectionId, executionTime: 1.5)

        let entry = await storage.fetch(
            QueryHistoryFilter(scope: .connection(connectionId)), after: nil, limit: 10
        ).entries.first

        #expect(entry?.firstRowTime == nil)
        #expect(entry?.serverTime == nil)
        #expect(entry?.databaseTime == 1.5)
    }

    // MARK: - Ranking

    @Test("The slowest panel ranks on database time, not on transfer")
    func slowestRanksOnDatabaseTime() async {
        let storage = makeStorage()
        let connectionId = UUID()
        // Slow only because it moved a lot of rows.
        await record(storage, "SELECT * FROM wide", connectionId: connectionId,
                     executionTime: 9.0, firstRowTime: 0.005)
        // Genuinely slow on the server, and quick to send.
        await record(storage, "SELECT count(*) FROM huge", connectionId: connectionId,
                     executionTime: 2.0, firstRowTime: 1.9)

        let snapshot = await storage.insights(
            QueryInsightsRequest(scope: .connection(connectionId)),
            slowestRanking: .totalTime
        )

        #expect(snapshot.slowest.first?.representativeQuery.contains("count(*)") == true)
    }

    @Test("A row written before the split existed still ranks on its elapsed time")
    func unmeasuredRowsStillRank() async {
        let storage = makeStorage()
        let connectionId = UUID()
        await record(storage, "SELECT * FROM slow_legacy", connectionId: connectionId, executionTime: 8.0)
        await record(storage, "SELECT * FROM fast", connectionId: connectionId,
                     executionTime: 5.0, firstRowTime: 0.004)

        let snapshot = await storage.insights(
            QueryInsightsRequest(scope: .connection(connectionId)),
            slowestRanking: .totalTime
        )

        #expect(snapshot.slowest.first?.representativeQuery.contains("slow_legacy") == true)
    }

    // MARK: - Migration

    /// A database written by the previous release has neither column. It must gain both, keep every
    /// row, and read exactly as it did before, because there is no honest value to backfill.
    @Test("A v4 database gains both columns without losing a row")
    func migratesFromVersionFour() async {
        let url = makeVersionFourDatabase(query: "SELECT * FROM legacy", executionTime: 2.5)

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let entries = await storage.fetch(QueryHistoryFilter(scope: .all), after: nil, limit: 10).entries

        #expect(columnNames(in: url, table: "history").isSuperset(of: ["first_row_time", "server_time"]))
        #expect(entries.count == 1)
        #expect(entries.first?.executionTime == 2.5)
        #expect(entries.first?.firstRowTime == nil)
        #expect(entries.first?.databaseTime == 2.5)
    }

    // MARK: - Fixtures

    private func makeVersionFourDatabase(query: String, executionTime: TimeInterval) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("history_v4_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK else { return url }
        defer { sqlite3_close_v2(db) }

        let statements = [
            """
            CREATE TABLE history (
                id TEXT PRIMARY KEY,
                query TEXT NOT NULL,
                connection_id TEXT NOT NULL,
                database_name TEXT NOT NULL,
                database_type TEXT NOT NULL DEFAULT '',
                schema_name TEXT,
                source TEXT NOT NULL DEFAULT 'editor',
                statement_type TEXT NOT NULL DEFAULT 'other',
                executed_at REAL NOT NULL,
                execution_time REAL NOT NULL,
                row_count INTEGER NOT NULL,
                was_successful INTEGER NOT NULL,
                error_message TEXT,
                fingerprint_hash INTEGER NOT NULL DEFAULT 0
            );
            """,
            """
            CREATE VIRTUAL TABLE history_fts USING fts5(
                query, content='history', content_rowid='rowid'
            );
            """,
            "PRAGMA user_version = 4;",
        ]
        for sql in statements {
            sqlite3_exec(db, sql, nil, nil, nil)
        }

        let insert = """
            INSERT INTO history (id, query, connection_id, database_name, database_type, schema_name,
                                 source, statement_type, executed_at, execution_time, row_count,
                                 was_successful, error_message, fingerprint_hash)
            VALUES (?, ?, ?, 'legacydb', 'PostgreSQL', NULL, 'editor', 'select', ?, ?, 3, 1, NULL, 0);
            """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, UUID().uuidString, -1, Self.transient)
            sqlite3_bind_text(statement, 2, query, -1, Self.transient)
            sqlite3_bind_text(statement, 3, UUID().uuidString, -1, Self.transient)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, executionTime)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)

        return url
    }

    private func columnNames(in url: URL, table: String) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close_v2(db) }

        var names: Set<String> = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return names
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: name))
            }
        }
        sqlite3_finalize(statement)
        return names
    }
}
