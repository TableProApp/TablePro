//
//  CompareRowServiceRefusalTests.swift
//  TableProTests
//

import Foundation
import XCTest

@testable import TablePro

@MainActor
final class CompareRowServiceRefusalTests: XCTestCase {
    private let connection = UUID()

    private func endpoint(database: String, schema: String? = nil, connectionId: UUID? = nil) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: connectionId ?? connection, database: database, schema: schema),
            connectionName: "staging",
            databaseType: .postgresql,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    /// Two scopes that are one scope reach one pooled entry, which runs its callers serially. The
    /// outer scope cannot finish until the inner one does and the inner one queues behind the
    /// outer, so the comparison would hang with nothing to report and leave the entry wedged.
    func testComparingAScopeWithItselfIsRefusedBeforeAnythingOpens() {
        let service = CompareRowService()
        let scope = endpoint(database: "shop")

        XCTAssertNotNil(service.concurrentReadRefusal(source: scope, target: scope))
    }

    func testTwoDatabasesOnOneConnectionAreNotRefusedForBeingTheSameScope() {
        let service = CompareRowService()

        let refusal = service.concurrentReadRefusal(
            source: endpoint(database: "shop"),
            target: endpoint(database: "shop_staging")
        )

        XCTAssertNotEqual(refusal, String(localized: "The source and the target are the same database."))
    }

    func testTwoSchemasInOneDatabaseAreTwoScopes() {
        let service = CompareRowService()

        let refusal = service.concurrentReadRefusal(
            source: endpoint(database: "shop", schema: "public"),
            target: endpoint(database: "shop", schema: "archive")
        )

        XCTAssertNotEqual(refusal, String(localized: "The source and the target are the same database."))
    }

    func testTwoConnectionsAreNeverRefused() {
        let service = CompareRowService()

        XCTAssertNil(
            service.concurrentReadRefusal(
                source: endpoint(database: "shop"),
                target: endpoint(database: "shop", connectionId: UUID())
            )
        )
    }
}
