//
//  SQLFavoriteStorage+Versions.swift
//  TablePro
//

import Foundation
import os
import SQLite3

extension SQLFavoriteStorage {
    private static let versionsLogger = Logger(subsystem: "com.TablePro", category: "SQLFavoriteVersions")

    static let retainedVersionCount = 50

    static var versionSchemaStatements: [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS favorite_versions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                favorite_id TEXT NOT NULL,
                name TEXT NOT NULL,
                query TEXT NOT NULL,
                saved_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_favorite_versions_favorite ON favorite_versions(favorite_id, id);",
            """
            CREATE TABLE IF NOT EXISTS favorite_query_times (
                favorite_id TEXT PRIMARY KEY,
                saved_at REAL NOT NULL
            );
            """,
            """
            INSERT OR IGNORE INTO favorite_query_times (favorite_id, saved_at)
            SELECT id, updated_at FROM favorites;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS favorites_version_ai AFTER INSERT ON favorites BEGIN
                DELETE FROM favorite_query_times WHERE favorite_id = new.id;
                INSERT INTO favorite_query_times (favorite_id, saved_at) VALUES (new.id, new.updated_at);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS favorites_version_au AFTER UPDATE OF query ON favorites
            WHEN old.query IS NOT new.query BEGIN
                INSERT INTO favorite_versions (favorite_id, name, query, saved_at)
                VALUES (
                    old.id, old.name, old.query,
                    COALESCE((SELECT saved_at FROM favorite_query_times WHERE favorite_id = old.id), old.updated_at)
                );
                DELETE FROM favorite_query_times WHERE favorite_id = new.id;
                INSERT INTO favorite_query_times (favorite_id, saved_at) VALUES (new.id, new.updated_at);
                DELETE FROM favorite_versions WHERE favorite_id = old.id AND id NOT IN (
                    SELECT id FROM favorite_versions WHERE favorite_id = old.id
                    ORDER BY id DESC LIMIT \(retainedVersionCount)
                );
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS favorites_version_ad AFTER DELETE ON favorites BEGIN
                DELETE FROM favorite_versions WHERE favorite_id = old.id;
                DELETE FROM favorite_query_times WHERE favorite_id = old.id;
            END;
            """,
        ]
    }

    func fetchVersions(favoriteId: UUID) -> [SQLFavoriteVersion] {
        let sql = """
            SELECT id, favorite_id, name, query, saved_at FROM favorite_versions
            WHERE favorite_id = ? ORDER BY id DESC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Self.versionsLogger.error("Failed to prepare version fetch: \(String(cString: sqlite3_errmsg(self.db)))")
            return []
        }

        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, favoriteId.uuidString, -1, SQLITE_TRANSIENT)

        var versions: [SQLFavoriteVersion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let version = Self.parseVersion(from: statement) {
                versions.append(version)
            }
        }
        return versions
    }

    func querySavedAt(favoriteId: UUID) -> Date? {
        let sql = "SELECT saved_at FROM favorite_query_times WHERE favorite_id = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, favoriteId.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    func replaceQuery(favoriteId: UUID, query: String, updatedAt: Date) -> FavoriteScopeWrite {
        guard case .found(let connectionId) = currentScope(table: "favorites", id: favoriteId) else {
            return .failed
        }

        let sql = "UPDATE favorites SET query = ?, updated_at = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return .failed
        }

        defer { sqlite3_finalize(statement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, updatedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, favoriteId.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            Self.versionsLogger.error("Failed to restore favorite: \(String(cString: sqlite3_errmsg(self.db)))")
            return .failed
        }
        return .updatedExisting(previousConnectionId: connectionId)
    }

    private static func parseVersion(from statement: OpaquePointer?) -> SQLFavoriteVersion? {
        guard let statement,
              let favoriteIdString = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
              let favoriteId = UUID(uuidString: favoriteIdString),
              let name = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
              let query = sqlite3_column_text(statement, 3).map({ String(cString: $0) })
        else {
            return nil
        }

        return SQLFavoriteVersion(
            id: sqlite3_column_int64(statement, 0),
            favoriteId: favoriteId,
            name: name,
            query: query,
            savedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        )
    }
}
