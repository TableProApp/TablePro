import Foundation
import SQLite3

// The core's copies written back as they are, times included, in one transaction: a collision the core settled, or a
// write of this build's that reached the core before the app ended. Nothing is written when a row moved since the
// mirror read it.
internal extension SQLFavoriteStorage {
    func applyCoreRecords(
        favorites: [SQLFavorite],
        folders: [SQLFavoriteFolder],
        removedFavoriteIds: [UUID],
        removedFolderIds: [UUID],
        expected: [SavedQueryMirrorKey: SavedQueryMirrorValue]
    ) -> Bool {
        // On the actor and before the transaction, so no write of this store comes between the check and the write.
        let touched = favorites.map { SavedQueryMirrorKey.query($0.id) } + folders.map { .folder($0.id) }
            + removedFavoriteIds.map { .query($0) } + removedFolderIds.map { .folder($0) }
        guard touched.allSatisfy({ current($0) == expected[$0] }) else { return false }
        return inTransaction { () -> Bool? in
            // Keywords move between rows here, and the unique index would refuse a row that takes one before the
            // row giving it up was removed or written, so removals and cleared keywords go first.
            guard delete(from: "favorites", ids: removedFavoriteIds),
                  delete(from: "folders", ids: removedFolderIds),
                  clearKeywords(of: favorites.map(\.id)),
                  folders.allSatisfy({ writeFolder($0) }),
                  favorites.allSatisfy({ writeFavorite($0) })
            else {
                return nil
            }
            return true
        } ?? false
    }

    private func current(_ key: SavedQueryMirrorKey) -> SavedQueryMirrorValue? {
        switch key {
        case .query(let id): fetchFavorite(id: id).map { .query(.init($0)) }
        case .folder(let id): fetchFolder(id: id).map { .folder(.init($0)) }
        }
    }

    private func clearKeywords(of ids: [UUID]) -> Bool {
        ids.isEmpty || run(
            "UPDATE favorites SET keyword = NULL WHERE id IN (\(Self.placeholders(count: ids.count)));",
            bindings: ids.map(\.uuidString)
        )
    }

    private func delete(from table: String, ids: [UUID]) -> Bool {
        ids.isEmpty || run(
            "DELETE FROM \(table) WHERE id IN (\(Self.placeholders(count: ids.count)));",
            bindings: ids.map(\.uuidString)
        )
    }

    private func writeFavorite(_ favorite: SQLFavorite) -> Bool {
        let sql = """
            INSERT INTO favorites (id, name, query, keyword, folder_id, connection_id, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, query = excluded.query, keyword = excluded.keyword,
                folder_id = excluded.folder_id, connection_id = excluded.connection_id,
                sort_order = excluded.sort_order, created_at = excluded.created_at, updated_at = excluded.updated_at;
            """
        return step(sql) { statement in
            Self.bind(favorite.id.uuidString, to: statement, at: 1)
            Self.bind(favorite.name, to: statement, at: 2)
            Self.bind(favorite.query, to: statement, at: 3)
            Self.bind(favorite.keyword, to: statement, at: 4)
            Self.bind(favorite.folderId?.uuidString, to: statement, at: 5)
            Self.bind(favorite.connectionId?.uuidString, to: statement, at: 6)
            sqlite3_bind_int(statement, 7, Int32(clamping: favorite.sortOrder))
            sqlite3_bind_double(statement, 8, favorite.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 9, favorite.updatedAt.timeIntervalSince1970)
        }
    }

    private func writeFolder(_ folder: SQLFavoriteFolder) -> Bool {
        let sql = """
            INSERT INTO folders (id, name, parent_id, connection_id, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, parent_id = excluded.parent_id, connection_id = excluded.connection_id,
                sort_order = excluded.sort_order, created_at = excluded.created_at, updated_at = excluded.updated_at;
            """
        return step(sql) { statement in
            Self.bind(folder.id.uuidString, to: statement, at: 1)
            Self.bind(folder.name, to: statement, at: 2)
            Self.bind(folder.parentId?.uuidString, to: statement, at: 3)
            Self.bind(folder.connectionId?.uuidString, to: statement, at: 4)
            sqlite3_bind_int(statement, 5, Int32(clamping: folder.sortOrder))
            sqlite3_bind_double(statement, 6, folder.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, folder.updatedAt.timeIntervalSince1970)
        }
    }

    private func step(_ sql: String, binding: (OpaquePointer?) -> Void) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        binding(statement)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private static func bind(_ text: String?, to statement: OpaquePointer?, at index: Int32) {
        guard let text else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func placeholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
