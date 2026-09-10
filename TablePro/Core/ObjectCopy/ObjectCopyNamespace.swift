//
//  ObjectCopyNamespace.swift
//  TablePro
//
//  The name an engine qualifies its objects with.
//
//  Not the same question as "which schema is selected". MySQL and MariaDB have
//  no schemas at all, yet `information_schema` reports the database in the
//  schema column, so their foreign keys, routines and triggers come back
//  qualified by the database name and their DDL is written that way. Reading
//  `endpoint.schema` there answers nil, which silently dropped every foreign
//  key edge from the dependency sort and made the same-namespace test that
//  guards definition copying compare nil against nil on two different
//  databases.
//

import Foundation
import TableProPluginKit

internal enum ObjectCopyNamespace {
    /// What this engine calls the namespace of the objects at `endpoint`.
    ///
    /// A schema where the engine has schemas, the database where it has databases but no schemas,
    /// and nothing at all where it has neither. Derived from the two capabilities the plugin
    /// registry already publishes rather than from a list of engine names, so a driver added later
    /// answers without being enumerated here.
    internal static func name(
        for endpoint: DatabaseEndpoint,
        supportsSchemas: Bool,
        supportsDatabases: Bool
    ) -> String? {
        if supportsSchemas { return endpoint.schema?.nilIfEmpty }
        guard supportsDatabases else { return nil }
        return endpoint.database.nilIfEmpty
    }

    /// Whether two endpoints put their objects in the same namespace, which is what decides
    /// whether a definition written against the source resolves the same way in the target.
    internal static func isSame(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs ?? "").lowercased() == (rhs ?? "").lowercased()
    }
}

@MainActor
internal extension ObjectCopyNamespace {
    static func name(for endpoint: DatabaseEndpoint) -> String? {
        name(
            for: endpoint,
            supportsSchemas: PluginManager.shared.supportsSchemaSwitching(for: endpoint.databaseType),
            supportsDatabases: PluginManager.shared.supportsDatabaseSwitching(for: endpoint.databaseType)
        )
    }
}
