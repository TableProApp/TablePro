//
//  EngineNamespaceSlot.swift
//  TablePro
//
//  Which container an engine qualifies its object names with.
//
//  Not the same question as "which container is selected". MySQL and MariaDB have no schemas at
//  all, yet `information_schema` reports the database in every column named for a schema, so a
//  foreign key, a routine or a trigger comes back qualified by the database name. A value read out
//  of a schema-named column therefore belongs in the database slot on those engines, and reading it
//  as a schema gives the same object two identities.
//
//  One answer, shared by everything that has to make the choice, so a capability change cannot move
//  one of them and leave the other behind.
//

import Foundation

internal enum EngineNamespaceSlot {
    case schema
    case database
    case unqualified

    internal init(supportsSchemas: Bool, supportsDatabases: Bool) {
        if supportsSchemas {
            self = .schema
            return
        }
        self = supportsDatabases ? .database : .unqualified
    }
}

@MainActor
internal extension EngineNamespaceSlot {
    init(databaseType: DatabaseType) {
        self.init(
            supportsSchemas: PluginManager.shared.supportsSchemaSwitching(for: databaseType),
            supportsDatabases: PluginManager.shared.supportsDatabaseSwitching(for: databaseType)
        )
    }
}
