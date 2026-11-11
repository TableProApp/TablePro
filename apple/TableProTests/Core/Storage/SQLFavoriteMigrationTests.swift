import Foundation
import SQLite3
@testable import TablePro
import Testing

struct SQLFavoriteMigrationTests {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql-favorite-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    // A version 1 store whose favorites.name allows NULL, which the version 2 table refuses.
    private func makeVersion1Database(favorites: [(id: UUID, name: String?, query: String)], folderId: UUID) -> URL {
        let url = scratch.appendingPathComponent("sql_favorites.db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK else { return url }
        defer { sqlite3_close_v2(db) }

        let schema = [
            """
            CREATE TABLE favorites (
                id TEXT PRIMARY KEY, name TEXT, query TEXT NOT NULL,
                keyword TEXT, folder_id TEXT, connection_id TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE folders (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, connection_id TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            """,
            "INSERT INTO folders (id, name, created_at, updated_at) VALUES ('\(folderId.uuidString)', 'Reports', 100, 100);",
            "PRAGMA user_version = 1;",
        ]
        for sql in schema {
            sqlite3_exec(db, sql, nil, nil, nil)
        }

        for favorite in favorites {
            var statement: OpaquePointer?
            let insert = "INSERT INTO favorites (id, name, query, created_at, updated_at) VALUES (?, ?, ?, 100, 100);"
            guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, favorite.id.uuidString, -1, Self.transient)
            if let name = favorite.name {
                sqlite3_bind_text(statement, 2, name, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_text(statement, 3, favorite.query, -1, Self.transient)
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

    @Test("A version 1 store migrates to version 2 with every saved query, folder and search entry")
    func version1StoreMigrates() async {
        let revenue = UUID()
        let churn = UUID()
        let folderId = UUID()
        let url = makeVersion1Database(
            favorites: [(id: revenue, name: "Revenue", query: "SELECT 1"), (id: churn, name: "Churn", query: "SELECT 2")],
            folderId: folderId
        )
        let storage = SQLFavoriteStorage(databaseURL: url)

        let favoriteIds = await storage.readAllFavorites()?.map(\.id)
        let folderIds = await storage.readAllFolders()?.map(\.id)
        let searched = await storage.fetchFavorites(searchText: "Churn").map(\.id)

        #expect(Set(favoriteIds ?? []) == [revenue, churn])
        #expect(folderIds == [folderId])
        #expect(searched == [churn])
        #expect(scalarInt(in: url, "PRAGMA user_version;") == 2)
        #expect(scalarInt(in: url, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('favorites_old', 'folders_old');") == 0)
    }

    @Test("A version 2 migration whose copy fails rolls back and keeps every saved query")
    func failedMigrationKeepsEverySavedQuery() async {
        let named = UUID()
        let unnamed = UUID()
        let url = makeVersion1Database(
            favorites: [(id: named, name: "Revenue", query: "SELECT 1"), (id: unnamed, name: nil, query: "SELECT 2")],
            folderId: UUID()
        )
        let storage = SQLFavoriteStorage(databaseURL: url)

        let readable = await storage.readAllFavorites()?.map(\.id)

        #expect(readable == [named])
        #expect(scalarInt(in: url, "SELECT COUNT(*) FROM favorites;") == 2)
        #expect(scalarInt(in: url, "SELECT COUNT(*) FROM folders;") == 1)
        #expect(scalarInt(in: url, "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('favorites_old', 'folders_old');") == 0)
        #expect(scalarInt(in: url, "PRAGMA user_version;") == 1)
    }
}
