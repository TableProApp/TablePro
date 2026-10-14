//
//  DatabaseEndpointTests.swift
//  TableProTests
//
//  What an endpoint used to get wrong before it was a scope rather than a connection id: it could
//  not address two databases on one server.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DatabaseEndpointTests {
    private let connectionId = UUID()

    private func endpoint(database: String, schema: String? = nil) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: database, schema: schema),
            connectionName: "server",
            databaseType: .postgresql,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    /// `canCompare` used to key on the connection id, which made this pair identical and refused
    /// the comparison the issue asks for by name: two versions of a schema on one server.
    @Test
    func twoDatabasesOnOneConnectionAreDistinctEndpoints() {
        #expect(endpoint(database: "app_prod").id != endpoint(database: "app_staging").id)
    }

    @Test
    func twoSchemasInOneDatabaseAreDistinctEndpoints() {
        #expect(endpoint(database: "app", schema: "public").id != endpoint(database: "app", schema: "sales").id)
    }

    @Test
    func theSameScopeIsTheSameEndpoint() {
        #expect(endpoint(database: "app", schema: "public").id == endpoint(database: "app", schema: "public").id)
    }

    @Test
    func qualifiedDescriptionNamesEveryLevelThatIsSet() {
        #expect(endpoint(database: "app", schema: "public").qualifiedDescription == "server / app / public")
        #expect(endpoint(database: "app").qualifiedDescription == "server / app")
        #expect(endpoint(database: "").qualifiedDescription == "server")
    }

    @Test
    func changingDatabaseClearsTheSchema() {
        let moved = endpoint(database: "app", schema: "public").withDatabase("other")

        #expect(moved.database == "other")
        #expect(moved.schema == nil)
    }

    @Test
    func readOnlyEndpointIsRefusedAsATarget() {
        let readOnly = DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: "prod", schema: nil),
            connectionName: "prod",
            databaseType: .postgresql,
            safeModeLevel: .readOnly,
            color: .red
        )

        #expect(!readOnly.canBeWrittenTo)
        #expect(readOnly.ineligibleAsTargetReason != nil)
    }
}
