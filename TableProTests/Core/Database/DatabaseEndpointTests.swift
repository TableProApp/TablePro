//
//  DatabaseEndpointTests.swift
//  TableProTests
//
//  What an endpoint used to get wrong before it was a scope rather than a connection id: it could
//  not address two databases on one server.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class DatabaseEndpointTests: XCTestCase {
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
    func testTwoDatabasesOnOneConnectionAreDistinctEndpoints() {
        XCTAssertNotEqual(endpoint(database: "app_prod").id, endpoint(database: "app_staging").id)
    }

    func testTwoSchemasInOneDatabaseAreDistinctEndpoints() {
        XCTAssertNotEqual(
            endpoint(database: "app", schema: "public").id,
            endpoint(database: "app", schema: "sales").id
        )
    }

    func testTheSameScopeIsTheSameEndpoint() {
        XCTAssertEqual(endpoint(database: "app", schema: "public").id, endpoint(database: "app", schema: "public").id)
    }

    func testQualifiedDescriptionNamesEveryLevelThatIsSet() {
        XCTAssertEqual(endpoint(database: "app", schema: "public").qualifiedDescription, "server / app / public")
        XCTAssertEqual(endpoint(database: "app").qualifiedDescription, "server / app")
        XCTAssertEqual(endpoint(database: "").qualifiedDescription, "server")
    }

    func testChangingDatabaseClearsTheSchema() {
        let moved = endpoint(database: "app", schema: "public").withDatabase("other")

        XCTAssertEqual(moved.database, "other")
        XCTAssertNil(moved.schema)
    }

    func testReadOnlyEndpointIsRefusedAsATarget() {
        let readOnly = DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId, database: "prod", schema: nil),
            connectionName: "prod",
            databaseType: .postgresql,
            safeModeLevel: .readOnly,
            color: .red
        )

        XCTAssertFalse(readOnly.canBeWrittenTo)
        XCTAssertNotNil(readOnly.ineligibleAsTargetReason)
    }
}
