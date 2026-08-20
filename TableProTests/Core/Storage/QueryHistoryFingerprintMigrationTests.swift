//
//  QueryHistoryFingerprintMigrationTests.swift
//  TableProTests
//
//  The v4 upgrade path: an existing history database gains a fingerprint column and every row
//  already in it is backfilled, so insights are not blank for everyone who already uses the app.
//

import Foundation
import SQLite3
@testable import TablePro
import Testing

@Suite("QueryHistoryStorage fingerprint migration")
struct QueryHistoryFingerprintMigrationTests {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Builds a database in the shape a shipped release left behind: current in every respect
    /// except that it predates `fingerprint_hash`.
    private func makeVersion3Database(queries: [String], connectionId: UUID) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("v3_history_\(UUID().uuidString).db")
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
                error_message TEXT
            );
            """,
            """
            CREATE VIRTUAL TABLE history_fts USING fts5(
                query, content='history', content_rowid='rowid', prefix='2 3 4'
            );
            """,
            """
            CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
                INSERT INTO history_fts(rowid, query) VALUES (new.rowid, new.query);
            END;
            """,
            "PRAGMA user_version = 3;"
        ]
        for sql in statements {
            sqlite3_exec(db, sql, nil, nil, nil)
        }

        for query in queries {
            let insert = """
                INSERT INTO history (id, query, connection_id, database_name, database_type,
                                     source, statement_type, executed_at, execution_time,
                                     row_count, was_successful, error_message)
                VALUES (?, ?, ?, 'legacydb', 'PostgreSQL', 'editor', 'select', ?, 0.25, 7, 1, NULL);
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, UUID().uuidString, -1, Self.transient)
            sqlite3_bind_text(statement, 2, query, -1, Self.transient)
            sqlite3_bind_text(statement, 3, connectionId.uuidString, -1, Self.transient)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }

        return url
    }

    @Test("Opening a v3 database backfills every existing row")
    func migrationBackfillsExistingRows() async {
        let connectionId = UUID()
        let url = makeVersion3Database(
            queries: [
                "SELECT * FROM users WHERE id = 1",
                "SELECT * FROM users WHERE id = 2",
                "SELECT * FROM users WHERE id = 3",
                "SELECT * FROM orders WHERE id = 1",
            ],
            connectionId: connectionId
        )

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let snapshot = await storage.insights(
            QueryInsightsRequest(scope: .connection(connectionId)),
            slowestRanking: .totalTime
        )

        #expect(snapshot.totals.totalCount == 4)
        // Three of the four differ only by a literal, so a backfilled store reports two shapes.
        // An unfilled column would leave every row hashed 0 and report one.
        #expect(snapshot.totals.distinctShapeCount == 2)
        #expect(snapshot.mostRun.first?.callCount == 3)
        #expect(snapshot.mostRun.first?.normalizedQuery == "SELECT * FROM users WHERE id = ?")
    }

    @Test("The migration is idempotent, so reopening does not redo or corrupt it")
    func migrationIsIdempotent() async {
        let connectionId = UUID()
        let url = makeVersion3Database(
            queries: ["SELECT * FROM t WHERE id = 1", "SELECT * FROM t WHERE id = 2"],
            connectionId: connectionId
        )

        let first = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: false)
        let firstSnapshot = await first.insights(
            QueryInsightsRequest(scope: .connection(connectionId)),
            slowestRanking: .totalTime
        )
        #expect(firstSnapshot.totals.distinctShapeCount == 1)

        let second = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let secondSnapshot = await second.insights(
            QueryInsightsRequest(scope: .connection(connectionId)),
            slowestRanking: .totalTime
        )
        #expect(secondSnapshot.totals.totalCount == 2)
        #expect(secondSnapshot.totals.distinctShapeCount == 1)
    }

    @Test("A row written after the migration is fingerprinted with the ones migrated before it")
    func newRowsJoinBackfilledGroups() async {
        let connectionId = UUID()
        let url = makeVersion3Database(
            queries: ["SELECT * FROM users WHERE id = 1"],
            connectionId: connectionId
        )

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        _ = await storage.record(QueryHistoryEntry(
            query: "SELECT * FROM users WHERE id = 99",
            connectionId: connectionId,
            databaseName: "legacydb",
            databaseType: .postgresql,
            source: .editor,
            executionTime: 0.25,
            rowCount: 7,
            wasSuccessful: true
        ))

        let snapshot = await storage.insights(
            QueryInsightsRequest(scope: .connection(connectionId)),
            slowestRanking: .totalTime
        )
        #expect(snapshot.totals.totalCount == 2)
        #expect(snapshot.totals.distinctShapeCount == 1)
        #expect(snapshot.mostRun.first?.callCount == 2)
    }
}
