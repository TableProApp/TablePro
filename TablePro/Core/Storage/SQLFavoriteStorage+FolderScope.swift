//
//  SQLFavoriteStorage+FolderScope.swift
//  TablePro
//

import Foundation
import SQLite3

internal extension SQLFavoriteStorage {
    /// The folder with this id whatever connection owns it.
    ///
    /// `fetchFolders(connectionId:)` answers only what one connection can see, which is the right
    /// question for the sidebar and the wrong one for the edit dialog: a favorite can name a folder
    /// belonging to a connection other than the one the dialog is open on, and the dialog has to be
    /// able to show that folder's name rather than an empty selection it would then save over.
    func fetchFolder(id: UUID) -> SQLFavoriteFolder? {
        let sql = """
            SELECT id, name, parent_id, connection_id, sort_order, created_at, updated_at
            FROM folders WHERE id = ?;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return parseFolder(from: statement)
    }

    /// Renames one folder without writing any of its other columns.
    ///
    /// `updateFolder` writes the whole record, so renaming from a copy the view model was holding
    /// would put that copy's `connection_id` back and undo a scope another window had just set. The
    /// same read-modify-write rule the connection library follows.
    func renameFolder(id: UUID, name: String) -> FavoriteScopeWrite {
        guard case .found(let connectionId) = currentScope(table: "folders", id: id) else {
            return .failed
        }

        let sql = "UPDATE folders SET name = ?, updated_at = ? WHERE id = ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return .failed }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, id.uuidString, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else { return .failed }
        return .updatedExisting(previousConnectionId: connectionId)
    }

    /// Moves one favorite between folders without writing any of its other columns, for the same
    /// reason `renameFolder` exists.
    func setFavoriteFolder(id: UUID, folderId: UUID?) -> FavoriteScopeWrite {
        guard case .found(let previousConnectionId) = currentScope(table: "favorites", id: id) else {
            return .failed
        }

        let sql = "UPDATE favorites SET folder_id = ?, updated_at = ? WHERE id = ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return .failed }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let folderId = folderId?.uuidString {
            sqlite3_bind_text(statement, 1, folderId, -1, transient)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, id.uuidString, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else { return .failed }
        return .updatedExisting(previousConnectionId: previousConnectionId)
    }

    /// Puts one folder in a scope, and touches nothing else.
    ///
    /// No relative comes with it, in either direction, because `FavoritesTreeBuilder` already
    /// places every row whose container this connection cannot resolve: a folder made available
    /// everywhere is drawn at the root of the connections that cannot see its parent, exactly as a
    /// global query inside a connection's folder already is, and a folder confined to one
    /// connection leaves whatever it held to be re-homed the same way. One rule, one row.
    ///
    /// Walking relatives is also how a scope change reaches records the user never selected. Taking
    /// the ancestors of a folder publishes their names, which are often a client's or a project's,
    /// to every connection; taking the subtree reassigns folders another connection owns to
    /// whichever window the menu was open in. Neither is undone by clicking the item again.
    func setFolderScope(id: UUID, connectionId: UUID?) -> FavoriteScopeWrite {
        guard case .found(let previousConnectionId) = currentScope(table: "folders", id: id) else {
            return .failed
        }

        let sql = "UPDATE folders SET connection_id = ?, updated_at = ? WHERE id = ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return .failed }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let connectionId = connectionId?.uuidString {
            sqlite3_bind_text(statement, 1, connectionId, -1, transient)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, id.uuidString, -1, transient)

        guard sqlite3_step(statement) == SQLITE_DONE else { return .failed }
        return .updatedExisting(previousConnectionId: previousConnectionId)
    }
}
