//
//  AllTablesListing.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the sidebar's Show All Tables command opens for an engine.
enum AllTablesListing: Equatable {
    /// A shell command, run in this window's new tab like any command the user types.
    case shellCommand(String)
    /// The plugin's own listing, opened in a tab of its own window.
    case statement(String)

    /// The plugin's listing when it builds one. The MongoDB and Redis plugins build none, so their shell's own
    /// command stands in, chosen by engine: Elasticsearch, Typesense and Weaviate also highlight as
    /// JavaScript and etcd as a command line, and none of them runs these.
    static func resolve(databaseType: DatabaseType, pluginListing: String?) -> AllTablesListing? {
        if let pluginListing {
            return .statement(pluginListing)
        }
        switch databaseType {
        case .mongodb:
            return .shellCommand(#"db.runCommand({"listCollections": 1, "nameOnly": false})"#)
        case .redis:
            return .shellCommand("SCAN 0 MATCH * COUNT 100")
        default:
            return nil
        }
    }
}
