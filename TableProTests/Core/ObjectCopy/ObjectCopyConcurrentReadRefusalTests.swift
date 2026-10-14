//
//  ObjectCopyConcurrentReadRefusalTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
final class ObjectCopyConcurrentReadRefusalTests {
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

    @Test
    func aCopyBetweenTwoSchemasOfOneConnectionIsRefusedInCopyWording() throws {
        let refusal = try #require(copyRefusal(
            source: endpoint(database: "shop", schema: "main"),
            target: endpoint(database: "shop", schema: "archive")
        ))

        #expect(!refusal.localizedCaseInsensitiveContains("compare"))
        #expect(refusal.contains("schemas"))
    }

    @Test
    func aCopyBetweenTwoDatabasesOfOneConnectionIsRefusedInCopyWording() throws {
        let refusal = try #require(copyRefusal(
            source: endpoint(database: "shop", schema: nil),
            target: endpoint(database: "shop_archive", schema: nil)
        ))

        #expect(!refusal.localizedCaseInsensitiveContains("compare"))
        #expect(refusal.contains("databases"))
    }

    @Test
    func aCopyOntoItsOwnScopeIsRefusedInCopyWording() {
        let scope = endpoint(database: "shop", schema: "main")

        #expect(copyRefusal(source: scope, target: scope) == String(localized: "The source and the target are the same database. Choose a different target."))
    }

    @Test
    func twoConnectionsAreNeverRefused() {
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

        #expect(refusal == nil)
    }
}
