//
//  ObjectRenameEligibility.swift
//  TablePro
//

import Foundation

/// Which rows offer Rename.
///
/// A container is never renamed while the connection is on it, the same rule Drop already
/// applies. Several engines refuse outright, PostgreSQL among them with "the current database
/// cannot be renamed", and the ones that allow it leave the session pointing at a name that no
/// longer exists. Switching away first is the gesture Drop already asks for.
enum ObjectRenameEligibility {
    struct Context {
        let activeDatabase: String?
        let activeSchema: String?
        let supportsRenameTable: Bool
        let supportsRenameView: Bool
        let supportsRenameDatabase: Bool
        let supportsRenameSchema: Bool
        let isReadOnly: Bool
    }

    /// Asked per object kind, not per engine. SQLite's one rename statement refuses a view and
    /// the engines built on it inherit that, so offering the item on a view there guarantees a
    /// failure alert for something the menu promised.
    static func canRename(table: TableInfo, context: Context) -> Bool {
        guard !context.isReadOnly else { return false }
        switch table.type {
        case .systemTable:
            return false
        case .view, .materializedView:
            return context.supportsRenameView
        case .table, .foreignTable, .partitionedTable, .externalTable:
            return context.supportsRenameTable
        }
    }

    static func renameable(_ targets: [DatabaseContainerRef], context: Context) -> DatabaseContainerRef? {
        guard !context.isReadOnly else { return nil }
        /// One at a time. A rename names one new name, so a multi-row selection has nothing to
        /// apply, and offering the item over one would silently act on a row the user did not
        /// mean.
        guard targets.count == 1, let target = targets.first else { return nil }
        return isRenameable(target, context: context) ? target : nil
    }

    private static func isRenameable(_ target: DatabaseContainerRef, context: Context) -> Bool {
        guard !target.isSystem else { return false }
        switch target.kind {
        case .database:
            guard context.supportsRenameDatabase else { return false }
            return target.database != context.activeDatabase
        case .schema:
            guard context.supportsRenameSchema else { return false }
            guard target.database == context.activeDatabase else { return true }
            return target.schema != context.activeSchema
        }
    }
}
