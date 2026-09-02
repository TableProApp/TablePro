//
//  QueryHistoryMigrationTests.swift
//  TableProTests
//
//  Opens a database frozen at the pre-rewrite schema and checks the v3 migration
//  keeps the user's rows, backfills the new columns, and drops the plaintext
//  parameter values the old schema captured.
//

import Foundation
import SQLite3
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("QueryHistoryStorage migration")
struct QueryHistoryMigrationTests {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func makeLegacyDatabase(
        rows: [(id: UUID, query: String, connectionId: UUID, executedAt: Date, parameterValues: String?)]
    ) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("legacy_history_\(UUID().uuidString).db")
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
                executed_at REAL NOT NULL,
                execution_time REAL NOT NULL,
                row_count INTEGER NOT NULL,
                was_successful INTEGER NOT NULL,
                error_message TEXT,
                parameter_values TEXT
            );
            """,
            """
            CREATE VIRTUAL TABLE history_fts USING fts5(
                query, content='history', content_rowid='rowid'
            );
            """,
            """
            CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
                INSERT INTO history_fts(rowid, query) VALUES (new.rowid, new.query);
            END;
            """,
            "CREATE INDEX idx_history_connection ON history(connection_id);",
            "PRAGMA user_version = 2;"
        ]
        for sql in statements {
            sqlite3_exec(db, sql, nil, nil, nil)
        }

        for row in rows {
            let insert = """
                INSERT INTO history (id, query, connection_id, database_name, executed_at,
                                     execution_time, row_count, was_successful, error_message, parameter_values)
                VALUES (?, ?, ?, 'legacydb', ?, 0.5, 7, 1, NULL, ?);
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, row.id.uuidString, -1, Self.transient)
            sqlite3_bind_text(statement, 2, row.query, -1, Self.transient)
            sqlite3_bind_text(statement, 3, row.connectionId.uuidString, -1, Self.transient)
            sqlite3_bind_double(statement, 4, row.executedAt.timeIntervalSince1970)
            if let parameterValues = row.parameterValues {
                sqlite3_bind_text(statement, 5, parameterValues, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }

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

    private func scalarInt(in url: URL, sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close_v2(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @Test("migration keeps every existing row")
    func migrationPreservesRows() async {
        let connId = UUID()
        let url = makeLegacyDatabase(rows: [
            (UUID(), "SELECT * FROM legacy_one", connId, Date().addingTimeInterval(-60), nil),
            (UUID(), "UPDATE legacy_two SET a = 1", connId, Date(), nil)
        ])

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let entries = await storage.fetch(QueryHistoryFilter(scope: .connection(connId)), after: nil, limit: 100).entries

        #expect(entries.count == 2)
        #expect(entries.contains { $0.query == "SELECT * FROM legacy_one" })
        #expect(entries.contains { $0.query == "UPDATE legacy_two SET a = 1" })
    }

    @Test("migration backfills source so old rows stay visible under the default filter")
    func migrationBackfillsSource() async {
        let connId = UUID()
        let url = makeLegacyDatabase(rows: [
            (UUID(), "SELECT * FROM legacy", connId, Date(), nil)
        ])

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let entries = await storage.fetch(
            QueryHistoryFilter(scope: .connection(connId), sources: QueryHistorySource.userAuthored),
            after: nil,
            limit: 100
        ).entries

        #expect(entries.count == 1)
        #expect(entries.first?.source == .editor)
    }

    @Test("migration classifies statement types from the stored SQL")
    func migrationBackfillsStatementType() async {
        let connId = UUID()
        let url = makeLegacyDatabase(rows: [
            (UUID(), "SELECT 1", connId, Date().addingTimeInterval(-30), nil),
            (UUID(), "DELETE FROM t WHERE id = 1", connId, Date().addingTimeInterval(-20), nil),
            (UUID(), "ALTER TABLE t ADD COLUMN c INT", connId, Date().addingTimeInterval(-10), nil)
        ])

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let entries = await storage.fetch(QueryHistoryFilter(scope: .connection(connId)), after: nil, limit: 100).entries

        let byQuery = Dictionary(uniqueKeysWithValues: entries.map { ($0.query, $0.statementType) })
        #expect(byQuery["SELECT 1"] == .select)
        #expect(byQuery["DELETE FROM t WHERE id = 1"] == .delete)
        #expect(byQuery["ALTER TABLE t ADD COLUMN c INT"] == .ddl)
    }

    @Test("migration drops the plaintext parameter values column")
    func migrationDropsParameterValues() async {
        let connId = UUID()
        let url = makeLegacyDatabase(rows: [
            (UUID(), "SELECT * FROM users WHERE token = ?", connId, Date(), "[{\"value\":\"s3cr3t\"}]")
        ])

        #expect(columnNames(in: url, table: "history").contains("parameter_values"))

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        _ = await storage.count(scope: .all)

        #expect(columnNames(in: url, table: "history").contains("parameter_values") == false)
    }

    @Test("migration rebuilds the search index with prefix matching")
    func migrationRebuildsSearchIndex() async {
        let connId = UUID()
        let url = makeLegacyDatabase(rows: [
            (UUID(), "SELECT * FROM subscriptions", connId, Date(), nil)
        ])

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let entries = await storage.fetch(
            QueryHistoryFilter(scope: .connection(connId), searchText: "subscr"),
            after: nil,
            limit: 100
        ).entries

        #expect(entries.count == 1)
    }

    @Test("a fresh database never grows the plaintext parameter values column")
    func freshDatabaseHasNoParameterValues() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("fresh_history_\(UUID().uuidString).db")

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        _ = await storage.count(scope: .all)

        let columns = columnNames(in: url, table: "history")
        #expect(columns.contains("parameter_values") == false)
        #expect(columns.contains("source"))
        #expect(columns.contains("database_type"))
    }

    @Test("a version 1 database, which never had parameter values, still migrates")
    func versionOneDatabaseMigrates() async {
        let connId = UUID()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("v1_history_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        if sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK {
            sqlite3_exec(db, """
                CREATE TABLE history (
                    id TEXT PRIMARY KEY,
                    query TEXT NOT NULL,
                    connection_id TEXT NOT NULL,
                    database_name TEXT NOT NULL,
                    executed_at REAL NOT NULL,
                    execution_time REAL NOT NULL,
                    row_count INTEGER NOT NULL,
                    was_successful INTEGER NOT NULL,
                    error_message TEXT
                );
                """, nil, nil, nil)
            sqlite3_exec(db, "PRAGMA user_version = 1;", nil, nil, nil)
            let insert = """
                INSERT INTO history VALUES ('\(UUID().uuidString)', 'SELECT * FROM ancient',
                '\(connId.uuidString)', 'olddb', \(Date().timeIntervalSince1970), 0.1, 3, 1, NULL);
                """
            sqlite3_exec(db, insert, nil, nil, nil)
            sqlite3_close_v2(db)
        }

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let entries = await storage.fetch(QueryHistoryFilter(scope: .connection(connId)), after: nil, limit: 10).entries

        #expect(entries.count == 1)
        #expect(entries.first?.query == "SELECT * FROM ancient")
        #expect(entries.first?.source == .editor)
        #expect(entries.first?.statementType == .select)
    }

    @Test("migration runs once and is idempotent across reopens")
    func migrationIsIdempotent() async {
        let connId = UUID()
        let url = makeLegacyDatabase(rows: [
            (UUID(), "SELECT * FROM once", connId, Date(), nil)
        ])

        let first = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: false)
        #expect(await first.count(scope: .all) == 1)

        let second = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        #expect(await second.count(scope: .all) == 1)
        let entries = await second.fetch(QueryHistoryFilter(scope: .connection(connId)), after: nil, limit: 10).entries
        #expect(entries.first?.query == "SELECT * FROM once")
    }

    @Test("plan snapshot schema is added after legacy migration and is idempotent")
    func planSnapshotSchemaMigratesLegacyDatabaseIdempotently() async {
        let connectionId = UUID()
        let url = makeLegacyDatabase(rows: [
            (UUID(), "SELECT * FROM legacy_plan", connectionId, Date(), nil)
        ])

        let first = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: false)
        #expect(await first.count(scope: .all) == 1)
        #expect(columnNames(in: url, table: "plan_snapshots") == [
            "id", "history_id", "fingerprint_hash", "subject_sql", "connection_id",
            "database_name", "database_type", "schema_name", "variant_key", "format",
            "raw_plan", "byte_count", "execution_time", "captured_at", "is_pinned"
        ])
        #expect(scalarInt(in: url, sql: "PRAGMA user_version;") == 5)

        let second = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        #expect(await second.count(scope: .all) == 1)
        #expect(
            scalarInt(
                in: url,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'plan_snapshots';"
            ) == 1
        )
    }

    @Test("fresh plan snapshot schema is idempotent without changing schema version")
    func freshPlanSnapshotSchemaIsIdempotent() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("fresh_plan_history_\(UUID().uuidString).db")
        let first = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: false)
        #expect(await first.count(scope: .all) == 0)
        let second = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        #expect(await second.count(scope: .all) == 0)

        #expect(scalarInt(in: url, sql: "PRAGMA user_version;") == 5)
        #expect(
            scalarInt(
                in: url,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE name IN ("
                    + "'plan_snapshots', 'idx_plan_snapshots_identity', 'idx_plan_snapshots_retention');"
            ) == 3
        )
    }

    /// `history_id` is provenance, not ownership. History retention must leave the plan behind with
    /// a null link rather than cascading it away, which is what a pinned baseline depends on.
    @Test("deleting a history row nulls the plan link instead of deleting the plan")
    func historyDeletionNullsThePlanLink() async {
        let connectionId = UUID()
        let historyId = UUID()
        let url = makeLegacyDatabase(rows: [
            (historyId, "EXPLAIN SELECT 1", connectionId, Date(), nil)
        ])

        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let capture = QueryPlanCapture(
            id: UUID(),
            identity: QueryPlanIdentity(
                fingerprintHash: 1,
                scope: QueryPlanScope(
                    connectionId: connectionId,
                    databaseType: .postgresql,
                    databaseName: "legacydb",
                    schemaName: nil
                ),
                variantKey: .declared("explain"),
                format: .postgresJson
            ),
            subjectSQL: "SELECT 1",
            rawPlan: "plan",
            executionTime: 0.1,
            capturedAt: Date(),
            historyId: historyId
        )
        #expect(await storage.recordPlanSnapshot(capture))
        #expect(await storage.delete(id: historyId))

        #expect(scalarInt(in: url, sql: "SELECT COUNT(*) FROM plan_snapshots;") == 1)
        #expect(scalarInt(in: url, sql: "SELECT COUNT(*) FROM plan_snapshots WHERE history_id IS NULL;") == 1)
    }
}
