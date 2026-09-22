//
//  SQLFavoriteStorage+FolderScope.swift
//  TablePro
//

import Foundation
import SQLite3

/// What a folder scope change rewrote, so the caller can mark every one of those records dirty.
///
/// A scope change is never one row: making a folder available everywhere has to take its ancestors
/// with it, and confining one to a connection has to take its subfolders. Reporting a bare `Bool`
/// would leave the rows the walk touched out of the next push, and the other device would go on
/// placing them by the scope they no longer have.
internal struct FolderScopeChange: Equatable {
    internal let changedFolderIds: [UUID]

    internal static let none = FolderScopeChange(changedFolderIds: [])

    internal var isEmpty: Bool { changedFolderIds.isEmpty }
}

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

    /// Puts a folder in a scope, and takes with it whichever relatives the containment rule needs.
    ///
    /// A folder is never narrower than what it holds. Making one available in every connection
    /// therefore has to make its ancestors available too, or it would sit inside a folder that only
    /// one connection can open; confining one to a connection has to confine its subfolders, or
    /// they would outlive the folder that contains them.
    ///
    /// It rewrites folders alone and never a favorite's own scope. That is what keeps
    /// `idx_favorites_keyword_scope` out of it: narrowing a favorite could collide with a keyword
    /// the destination connection already holds, and the whole transaction would roll back with
    /// nothing to show the user. A favorite that stays global inside a confined folder is still
    /// reachable, because the tree re-homes it rather than hiding it.
    ///
    /// And it walks only through folders in the same scope as the one that was clicked, so it can
    /// never take a folder belonging to another connection. A connection may put its own folder
    /// inside a global one, and that folder is invisible to everybody else; without the boundary,
    /// confining the global parent from one connection would have quietly moved another
    /// connection's whole branch into this one.
    func setFolderScope(id: UUID, connectionId: UUID?) -> FolderScopeChange {
        guard case .found(let scope) = currentScope(table: "folders", id: id), scope != connectionId else {
            return .none
        }

        let rows = folderScopeRows()
        let pending = connectionId == nil
            ? Self.ancestorChain(from: id, in: rows, sharing: scope)
            : Self.folderSubtree(from: id, in: rows, sharing: scope)
        guard !pending.isEmpty else { return .none }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return .none }

        let updatedAt = Date().timeIntervalSince1970
        for folderId in pending {
            guard writeFolderScope(id: folderId, connectionId: connectionId, updatedAt: updatedAt) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return .none
            }
        }

        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return .none
        }
        return FolderScopeChange(changedFolderIds: pending)
    }
}

private extension SQLFavoriteStorage {
    struct FolderScopeRow {
        let id: UUID
        let parentId: UUID?
        let connectionId: UUID?
    }

    func folderScopeRows() -> [UUID: FolderScopeRow] {
        var statement: OpaquePointer?
        let sql = "SELECT id, parent_id, connection_id FROM folders;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var rows: [UUID: FolderScopeRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: raw)) else { continue }
            rows[id] = FolderScopeRow(
                id: id,
                parentId: sqlite3_column_text(statement, 1).flatMap { UUID(uuidString: String(cString: $0)) },
                connectionId: sqlite3_column_text(statement, 2).flatMap { UUID(uuidString: String(cString: $0)) }
            )
        }
        return rows
    }

    func writeFolderScope(id: UUID, connectionId: UUID?, updatedAt: TimeInterval) -> Bool {
        let sql = "UPDATE folders SET connection_id = ?, updated_at = ? WHERE id = ?;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let connectionId = connectionId?.uuidString {
            sqlite3_bind_text(statement, 1, connectionId, -1, transient)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_double(statement, 2, updatedAt)
        sqlite3_bind_text(statement, 3, id.uuidString, -1, transient)

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// The folder and every folder above it in the same scope, stopping at a parent that does not
    /// exist, one another connection owns, and one that leads back to somewhere the walk has
    /// already been. `parent_id` carries no foreign key and no check constraint, so a cycle is
    /// representable and a walk without a visited set does not terminate.
    static func ancestorChain(from id: UUID, in rows: [UUID: FolderScopeRow], sharing scope: UUID?) -> [UUID] {
        var chain: [UUID] = []
        var seen: Set<UUID> = []
        var cursor: UUID? = id
        while let current = cursor,
              let row = rows[current],
              row.connectionId == scope,
              seen.insert(current).inserted {
            chain.append(current)
            cursor = row.parentId
        }
        return chain
    }

    /// The folder and every folder under it in the same scope. A branch belonging to another
    /// connection ends the walk there rather than being taken, along with everything under it.
    static func folderSubtree(from id: UUID, in rows: [UUID: FolderScopeRow], sharing scope: UUID?) -> [UUID] {
        guard rows[id]?.connectionId == scope else { return [] }

        var childIdsByParent: [UUID: [UUID]] = [:]
        for row in rows.values where row.connectionId == scope {
            guard let parentId = row.parentId else { continue }
            childIdsByParent[parentId, default: []].append(row.id)
        }

        var subtree: [UUID] = []
        var seen: Set<UUID> = []
        var queue: [UUID] = [id]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            guard seen.insert(current).inserted else { continue }
            subtree.append(current)
            queue.append(contentsOf: childIdsByParent[current] ?? [])
        }
        return subtree
    }
}
