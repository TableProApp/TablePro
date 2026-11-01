//
//  AllTablesListingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct AllTablesListingTests {
    @Test("A plugin's own listing is the statement")
    func pluginListingWins() {
        let etcdListing = #"get "/" --prefix --keys-only"#

        #expect(AllTablesListing.statement(databaseType: .etcd, pluginListing: etcdListing) == etcdListing)
        #expect(AllTablesListing.statement(databaseType: .postgresql, pluginListing: "SELECT 1") == "SELECT 1")
    }

    @Test("MongoDB and Redis fall back to their shell's own listing")
    func shellFallbacks() {
        #expect(
            AllTablesListing.statement(databaseType: .mongodb, pluginListing: nil)
                == #"db.runCommand({"listCollections": 1, "nameOnly": false})"#
        )
        #expect(AllTablesListing.statement(databaseType: .redis, pluginListing: nil) == "SCAN 0 MATCH * COUNT 100")
    }

    @Test("An engine that only highlights like MongoDB or Redis gets no shell command", arguments: [
        DatabaseType.elasticsearch, .typesense, .weaviate, .qdrant, .etcd, .cassandra
    ])
    func noListingForOtherEngines(databaseType: DatabaseType) {
        #expect(AllTablesListing.statement(databaseType: databaseType, pluginListing: nil) == nil)
    }

    /// The scope is the tab's own, so a listing of `sales` lists `sales` whatever schema the shared
    /// driver was last moved to.
    @Test("The container comes from the listing's scope, escaped only when it is a schema")
    func containerFromTheScope() {
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "o'neil")
        let escape: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }

        #expect(AllTablesListing.container(slot: .schema, scope: scope, escapeLiteral: escape) == "o''neil")
        #expect(AllTablesListing.container(slot: .database, scope: scope, escapeLiteral: escape) == "shop")
        #expect(AllTablesListing.container(slot: .unqualified, scope: scope, escapeLiteral: escape) == nil)

        let serverScope = DatabaseScope(connectionId: UUID(), database: "", schema: nil)
        #expect(AllTablesListing.container(slot: .schema, scope: serverScope, escapeLiteral: escape) == nil)
        #expect(AllTablesListing.container(slot: .database, scope: serverScope, escapeLiteral: escape) == nil)
    }
}
