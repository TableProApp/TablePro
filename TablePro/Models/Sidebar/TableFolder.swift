//
//  TableFolder.swift
//  TablePro
//

import Foundation

/// A folder's scope is the database or schema it belongs to, spelled the way `TableScope` spells a
/// table's, so a catalog rename or drop reaches folders through the same sweep that reaches every
/// other per-table setting.
internal extension DatabaseScope {
    /// Whether this scope sits inside a database, or inside one schema of it when a schema is named.
    func isInside(database: String, schema: String?) -> Bool {
        guard self.database == database else { return false }
        guard let schema else { return true }
        return self.schema == schema
    }

    /// The same scope after its database, or one schema of it, was renamed. A nil `fromSchema`
    /// renames the database and keeps whatever schema the scope had.
    func moved(fromDatabase: String, fromSchema: String?, toDatabase: String, toSchema: String?) -> DatabaseScope? {
        guard isInside(database: fromDatabase, schema: fromSchema) else { return nil }
        return DatabaseScope(
            connectionId: connectionId,
            database: toDatabase,
            schema: fromSchema == nil ? schema : toSchema
        )
    }
}

/// A folder the user files tables and views into, inside one database or schema.
internal struct TableFolder: Identifiable, Hashable, Codable, Sendable {
    internal let id: UUID
    internal var scope: DatabaseScope
    internal var name: String
    internal let createdAt: Date
    internal var updatedAt: Date

    internal init(
        id: UUID = UUID(),
        scope: DatabaseScope,
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.scope = scope
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// One table or view filed in a folder. Keyed by the object, so an object is in at most one folder.
internal struct TableFolderItem: Hashable, Codable, Sendable {
    internal let scope: DatabaseScope
    internal let name: String
    internal var folderId: UUID

    internal var key: TableFolderItemKey {
        TableFolderItemKey(scope: scope, name: name)
    }

    internal var syncId: String {
        key.syncId
    }
}

internal struct TableFolderItemKey: Hashable, Codable, Sendable {
    internal let scope: DatabaseScope
    internal let name: String

    /// Escaped before it is hashed. Joined raw, schema `a|b` with table `c` and schema `a` with
    /// table `b|c` would hash to one record and overwrite each other in iCloud.
    internal var syncId: String {
        IdentityPath.joined(
            [scope.connectionId.uuidString, scope.database, scope.schema ?? "", name],
            separator: "|"
        ).sha256
    }
}

/// The folders of one scope and which of its objects each holds, as the sidebar reads them.
internal struct TableFolderLayout: Equatable, Sendable {
    internal let folders: [TableFolder]
    internal let placements: [String: UUID]

    internal static let empty = TableFolderLayout(folders: [], placements: [:])

    internal var isEmpty: Bool { folders.isEmpty }
}
