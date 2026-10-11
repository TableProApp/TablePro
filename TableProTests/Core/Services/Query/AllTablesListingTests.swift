//
//  AllTablesListingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct AllTablesListingTests {
    @Test("A plugin's own listing opens as a statement")
    func pluginListingWins() {
        let etcdListing = #"get "/" --prefix --keys-only"#

        #expect(
            AllTablesListing.resolve(databaseType: .etcd, pluginListing: etcdListing) == .statement(etcdListing)
        )
        #expect(
            AllTablesListing.resolve(databaseType: .postgresql, pluginListing: "SELECT 1") == .statement("SELECT 1")
        )
    }

    @Test("MongoDB and Redis fall back to their shell's own listing")
    func shellFallbacks() {
        #expect(
            AllTablesListing.resolve(databaseType: .mongodb, pluginListing: nil)
                == .shellCommand(#"db.runCommand({"listCollections": 1, "nameOnly": false})"#)
        )
        #expect(
            AllTablesListing.resolve(databaseType: .redis, pluginListing: nil) == .shellCommand("SCAN 0 MATCH * COUNT 100")
        )
    }

    @Test("An engine that only highlights like MongoDB or Redis gets no shell command", arguments: [
        DatabaseType.elasticsearch, .typesense, .weaviate, .etcd, .cassandra
    ])
    func noListingForOtherEngines(databaseType: DatabaseType) {
        #expect(AllTablesListing.resolve(databaseType: databaseType, pluginListing: nil) == nil)
    }
}
