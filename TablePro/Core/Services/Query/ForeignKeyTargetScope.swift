//
//  ForeignKeyTargetScope.swift
//  TablePro
//
//  Where a foreign key points, in the vocabulary the rest of the app keys on.
//

import Foundation
import TableProPluginKit

/// The referenced table's own scope, resolved once and used for every question about it: which
/// connection to route the lookup through, which key its remembered settings hang on, and which
/// database and schema a tab opened on it carries.
///
/// `ForeignKeyInfo.referencedSchema` is whatever the engine's catalog puts in its schema column,
/// which on an engine with no schema layer is a database name. Every other per-table setting builds
/// its `TableScope` from the tab's own schema, which is nil there, so writing the raw value into the
/// schema slot gave one table two keys and left its foreign key label behind on a rename. The same
/// value reached tab identity, where it split a table reached through a key from the same table
/// opened from the sidebar.
internal enum ForeignKeyTargetScope {
    internal static func resolve(
        origin: DatabaseScope,
        referencedDatabase: String? = nil,
        referencedSchema: String?,
        slot: EngineNamespaceSlot
    ) -> DatabaseScope {
        let database = referencedDatabase?.nilIfEmpty
        guard let referenced = referencedSchema?.nilIfEmpty else {
            guard let database, slot == .schema else { return origin }
            return DatabaseScope(
                connectionId: origin.connectionId, database: database, schema: origin.schema
            )
        }
        switch slot {
        case .schema:
            /// Only an engine that names objects in three parts reports a referenced database, and
            /// only that arm can carry one: the others already hold a database in this slot.
            return DatabaseScope(
                connectionId: origin.connectionId,
                database: database ?? origin.database,
                schema: referenced
            )
        case .database:
            return DatabaseScope(
                connectionId: origin.connectionId, database: referenced, schema: nil
            )
        case .unqualified:
            return DatabaseScope(
                connectionId: origin.connectionId, database: origin.database, schema: nil
            )
        }
    }

    internal static func tableScope(
        origin: DatabaseScope,
        referencedDatabase: String? = nil,
        referencedSchema: String?,
        referencedTable: String,
        slot: EngineNamespaceSlot
    ) -> TableScope {
        let scope = resolve(
            origin: origin,
            referencedDatabase: referencedDatabase,
            referencedSchema: referencedSchema,
            slot: slot
        )
        return TableScope(
            connectionId: scope.connectionId,
            database: scope.database.nilIfEmpty,
            schema: scope.schema,
            table: referencedTable
        )
    }
}

@MainActor
internal extension ForeignKeyTargetScope {
    static func resolve(
        origin: DatabaseScope,
        referencedDatabase: String? = nil,
        referencedSchema: String?,
        databaseType: DatabaseType
    ) -> DatabaseScope {
        resolve(
            origin: origin,
            referencedDatabase: referencedDatabase,
            referencedSchema: referencedSchema,
            slot: EngineNamespaceSlot(databaseType: databaseType)
        )
    }

    static func tableScope(
        origin: DatabaseScope,
        referencedDatabase: String? = nil,
        referencedSchema: String?,
        referencedTable: String,
        databaseType: DatabaseType
    ) -> TableScope {
        tableScope(
            origin: origin,
            referencedDatabase: referencedDatabase,
            referencedSchema: referencedSchema,
            referencedTable: referencedTable,
            slot: EngineNamespaceSlot(databaseType: databaseType)
        )
    }
}
