//
//  AllTablesListing.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the sidebar's Show All Tables command lists for an engine, and for which container.
enum AllTablesListing {
    /// The plugin's listing when it builds one. The MongoDB and Redis plugins build none, so their shell's own
    /// command stands in, chosen by engine: Elasticsearch, Typesense and Weaviate also highlight as
    /// JavaScript and etcd as a command line, and none of them runs these.
    static func statement(databaseType: DatabaseType, pluginListing: String?) -> String? {
        if let pluginListing {
            return pluginListing
        }
        switch databaseType {
        case .mongodb:
            return #"db.runCommand({"listCollections": 1, "nameOnly": false})"#
        case .redis:
            return "SCAN 0 MATCH * COUNT 100"
        default:
            return nil
        }
    }

    /// The container a plugin's listing names, taken from the listing's own scope. The shared driver's
    /// schema is not it: a cross-database tab moves that and nothing moves it back. A schema goes over
    /// escaped as a string literal, the form the plugins have always been handed.
    static func container(
        slot: EngineNamespaceSlot,
        scope: DatabaseScope,
        escapeLiteral: (String) -> String
    ) -> String? {
        switch slot {
        case .schema:
            return scope.schema.map(escapeLiteral)
        case .database:
            return scope.database.isEmpty ? nil : scope.database
        case .unqualified:
            return nil
        }
    }
}
