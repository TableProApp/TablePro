//
//  QueryHistorySearchIndexTests.swift
//  TableProTests
//
//  Opens databases an older build left, with its search index and indexes, and checks the slimmer
//  schema replaces them once, keeps every search answer, and writes nothing on a later open.
//

import Foundation
import SQLite3
@testable import TablePro
import TableProPluginKit
import Testing

struct QueryHistorySearchIndexTests {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // 0.87.0's search index, and the plain one the builds before it made.
    private static let prefixSearchIndex = """
        CREATE VIRTUAL TABLE history_fts USING fts5(
            query,
            content='history',
            content_rowid='rowid',
            prefix='2 3 4'
        );
        """
    private static let plainSearchIndex = """
        CREATE VIRTUAL TABLE history_fts USING fts5(query, content='history', content_rowid='rowid');
        """

    private static let queries = [
        "SELECT * FROM customers WHERE id = 1",
        "SELECT * FROM payments ORDER BY created_at",
        "UPDATE orders SET status = 'paid' WHERE id = 7",
        "SELECT count(*) FROM sessions",
        "DELETE FROM customer_notes WHERE customer_id = 3",
    ]

    private static let searches = ["s", "se", "custo", "pay", "orders.id", "status paid"]

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("search_index_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        let path = url.path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func entry(_ query: String, connectionId: UUID, offset: TimeInterval) -> QueryHistoryEntry {
        QueryHistoryEntry(
            id: UUID(),
            query: query,
            connectionId: connectionId,
            databaseName: "app",
            databaseType: .postgresql,
            schemaName: nil,
            source: .editor,
            executedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true,
            errorMessage: nil
        )
    }

    // A database this build wrote, with its search index and indexes turned back into an older build's.
    private func makeOlderDatabase(searchIndex: String, fingerprintIndexes: Bool) async -> (URL, UUID) {
        let url = makeURL()
        let connectionId = UUID()
        await seed(url, connectionId: connectionId)
        var statements = [
            "DROP TRIGGER history_ai;",
            "DROP TRIGGER history_ad;",
            "DROP TABLE history_fts;",
            searchIndex,
            """
            CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
                INSERT INTO history_fts(rowid, query) VALUES (new.rowid, new.query);
            END;
            """,
            """
            CREATE TRIGGER history_ad AFTER DELETE ON history BEGIN
                INSERT INTO history_fts(history_fts, rowid, query) VALUES('delete', old.rowid, old.query);
            END;
            """,
            "INSERT INTO history_fts(history_fts) VALUES('rebuild');",
        ]
        if fingerprintIndexes {
            statements.append(
                "CREATE INDEX idx_history_fingerprint_executed ON history(fingerprint_hash, executed_at DESC);"
            )
            statements.append("""
                CREATE INDEX idx_history_fingerprint_connection_executed
                    ON history(fingerprint_hash, connection_id, executed_at DESC);
                """)
        }
        withDatabase(url) { db in
            for sql in statements {
                sqlite3_exec(db, sql, nil, nil, nil)
            }
        }
        return (url, connectionId)
    }

    private func seed(_ url: URL, connectionId: UUID) async {
        let storage = QueryHistoryStorage(databaseURL: url)
        for (index, query) in Self.queries.enumerated() {
            _ = await storage.record(entry(query, connectionId: connectionId, offset: Double(index)))
        }
    }

    private func withDatabase<T>(_ url: URL, _ body: (OpaquePointer?) -> T) -> T {
        var db: OpaquePointer?
        sqlite3_open(url.path(percentEncoded: false), &db)
        defer { sqlite3_close_v2(db) }
        return body(db)
    }

    private func text(in url: URL, sql: String) -> String? {
        withDatabase(url) { db in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0)
            else { return nil }
            return String(cString: value)
        }
    }

    private func names(in url: URL, type: String) -> Set<String> {
        withDatabase(url) { db in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            var names: Set<String> = []
            guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = '\(type)';", -1, &statement, nil)
                == SQLITE_OK else { return names }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 0) {
                    names.insert(String(cString: name))
                }
            }
            return names
        }
    }

    // What a search returns straight from the index, before any build of this app opened it.
    private func rawSearch(in url: URL, _ searchText: String) -> Set<String> {
        withDatabase(url) { db in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            var ids: Set<String> = []
            let sql = """
                SELECT h.id FROM history h INNER JOIN history_fts ON h.rowid = history_fts.rowid
                WHERE history_fts MATCH ?;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return ids }
            sqlite3_bind_text(statement, 1, QueryHistoryStorage.ftsQuery(for: searchText), -1, Self.transient)
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = sqlite3_column_text(statement, 0) {
                    ids.insert(String(cString: id))
                }
            }
            return ids
        }
    }

    private func search(_ storage: QueryHistoryStorage, _ searchText: String) async -> Set<String> {
        let entries = await storage.fetch(
            QueryHistoryFilter(scope: .all, sources: Set(QueryHistorySource.allCases), searchText: searchText),
            after: nil,
            limit: 100
        ).entries
        return Set(entries.map(\.id.uuidString))
    }

    private func expectIntegrity(_ url: URL) {
        let result = withDatabase(url) { db in
            sqlite3_exec(db, "INSERT INTO history_fts(history_fts, rank) VALUES('integrity-check', 1);", nil, nil, nil)
        }
        #expect(result == SQLITE_OK)
    }

    @Test(
        "An older search index is rebuilt slim and answers every search the same",
        arguments: [Self.prefixSearchIndex, Self.plainSearchIndex]
    )
    func olderSearchIndexIsRebuilt(searchIndex: String) async throws {
        let (url, _) = await makeOlderDatabase(searchIndex: searchIndex, fingerprintIndexes: false)
        defer { remove(url) }
        let before = Dictionary(uniqueKeysWithValues: Self.searches.map { ($0, rawSearch(in: url, $0)) })
        #expect(before["custo"]?.count == 2)

        let storage = QueryHistoryStorage(databaseURL: url)
        for searchText in Self.searches {
            #expect(await search(storage, searchText) == before[searchText], "search \(searchText)")
        }

        let sql = try #require(text(in: url, sql: "SELECT sql FROM sqlite_master WHERE name = 'history_fts';"))
        #expect(sql.contains("columnsize=0"))
        #expect(!sql.contains("prefix"))
        #expect(!names(in: url, type: "table").contains("history_fts_docsize"))
        expectIntegrity(url)
    }

    @Test("A deleted row leaves the rebuilt index whole and out of the search")
    func deleteKeepsTheRebuiltIndexWhole() async throws {
        let (url, _) = await makeOlderDatabase(searchIndex: Self.prefixSearchIndex, fingerprintIndexes: false)
        defer { remove(url) }
        let storage = QueryHistoryStorage(databaseURL: url)
        let payments = await search(storage, "payments")
        let id = try #require(payments.first.flatMap(UUID.init(uuidString:)))

        #expect(await storage.delete(id: id))

        #expect(await search(storage, "payments").isEmpty)
        expectIntegrity(url)
    }

    @Test("A 0.87.0 database loses the two fingerprint indexes and keeps the source index")
    func fingerprintIndexesAreDropped() async {
        let (url, _) = await makeOlderDatabase(searchIndex: Self.prefixSearchIndex, fingerprintIndexes: true)
        defer { remove(url) }
        #expect(names(in: url, type: "index").contains("idx_history_fingerprint_executed"))

        let storage = QueryHistoryStorage(databaseURL: url)
        #expect(await storage.count(scope: .all) == Self.queries.count)

        let indexes = names(in: url, type: "index")
        #expect(!indexes.contains("idx_history_fingerprint_executed"))
        #expect(!indexes.contains("idx_history_fingerprint_connection_executed"))
        #expect(indexes.contains("idx_history_source"))
        #expect(indexes.contains("idx_history_shape_executed"))
    }

    @Test("A later open rebuilds nothing and writes nothing")
    func laterOpenWritesNothing() async throws {
        let (url, _) = await makeOlderDatabase(searchIndex: Self.prefixSearchIndex, fingerprintIndexes: true)
        defer { remove(url) }
        await openAndRelease(url)
        let schemaVersion = text(in: url, sql: "PRAGMA schema_version;")

        let storage = QueryHistoryStorage(databaseURL: url)
        #expect(await storage.count(scope: .all) == Self.queries.count)

        #expect(text(in: url, sql: "PRAGMA schema_version;") == schemaVersion)
        let walPath = url.path(percentEncoded: false) + "-wal"
        let walSize = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int) ?? 0
        #expect(walSize == 0)
    }

    private func openAndRelease(_ url: URL) async {
        let storage = QueryHistoryStorage(databaseURL: url)
        _ = await storage.count(scope: .all)
    }

    @Test("A rebuild that cannot take the write lock keeps the old index and its searches")
    func failedRebuildKeepsTheOldIndex() async throws {
        let (url, _) = await makeOlderDatabase(searchIndex: Self.prefixSearchIndex, fingerprintIndexes: false)
        defer { remove(url) }
        let before = rawSearch(in: url, "custo")

        var holder: OpaquePointer?
        sqlite3_open(url.path(percentEncoded: false), &holder)
        #expect(sqlite3_exec(holder, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)

        let storage = QueryHistoryStorage(databaseURL: url)
        #expect(await search(storage, "custo") == before)

        sqlite3_exec(holder, "ROLLBACK;", nil, nil, nil)
        sqlite3_close_v2(holder)

        let sql = try #require(text(in: url, sql: "SELECT sql FROM sqlite_master WHERE name = 'history_fts';"))
        #expect(sql.contains("prefix"))
        #expect(await search(storage, "custo") == before)
        expectIntegrity(url)
    }
}
