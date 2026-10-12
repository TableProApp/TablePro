//
//  ObjectCopyConcurrentReadRefusalTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

@MainActor
final class ObjectCopyConcurrentReadRefusalTests: XCTestCase {
    private let connection = UUID()

    private func endpoint(database: String, schema: String?) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connection, database: database, schema: schema),
            connectionName: "warehouse",
            databaseType: .duckdb,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    private func copyRefusal(source: DatabaseEndpoint, target: DatabaseEndpoint) -> String? {
        ObjectCopyPlanner(manager: .shared).concurrentReadRefusal(source: source, target: target)
    }

    func testACopyBetweenTwoSchemasOfOneConnectionIsRefusedInCopyWording() throws {
        let refusal = try XCTUnwrap(copyRefusal(
            source: endpoint(database: "shop", schema: "main"),
            target: endpoint(database: "shop", schema: "archive")
        ))

        XCTAssertFalse(refusal.localizedCaseInsensitiveContains("compare"))
        XCTAssertTrue(refusal.contains("schemas"))
    }

    func testACopyBetweenTwoDatabasesOfOneConnectionIsRefusedInCopyWording() throws {
        let refusal = try XCTUnwrap(copyRefusal(
            source: endpoint(database: "shop", schema: nil),
            target: endpoint(database: "shop_archive", schema: nil)
        ))

        XCTAssertFalse(refusal.localizedCaseInsensitiveContains("compare"))
        XCTAssertTrue(refusal.contains("databases"))
    }

    func testACopyOntoItsOwnScopeIsRefusedInCopyWording() {
        let scope = endpoint(database: "shop", schema: "main")

        XCTAssertEqual(
            copyRefusal(source: scope, target: scope),
            String(localized: "The source and the target are the same database. Choose a different target.")
        )
    }

    func testTwoConnectionsAreNeverRefused() {
        let refusal = copyRefusal(
            source: endpoint(database: "shop", schema: "main"),
            target: DatabaseEndpoint(
                scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: "archive"),
                connectionName: "backup",
                databaseType: .duckdb,
                safeModeLevel: .silent,
                color: .blue
            )
        )

        XCTAssertNil(refusal)
    }
}
