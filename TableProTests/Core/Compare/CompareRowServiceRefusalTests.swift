//
//  CompareRowServiceRefusalTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
final class CompareRowServiceRefusalTests {
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
    @Test
    func comparingAScopeWithItselfIsRefusedBeforeAnythingOpens() {
        let service = CompareRowService()
        let scope = endpoint(database: "shop")

        #expect(service.concurrentReadRefusal(source: scope, target: scope) == .sameScope)
    }

    @Test
    func twoDatabasesOnOneConnectionAreNotRefusedForBeingTheSameScope() {
        let service = CompareRowService()

        let refusal = service.concurrentReadRefusal(
            source: endpoint(database: "shop"),
            target: endpoint(database: "shop_staging")
        )

        #expect(refusal != .sameScope)
    }

    @Test
    func twoSchemasInOneDatabaseAreTwoScopes() {
        let service = CompareRowService()

        let refusal = service.concurrentReadRefusal(
            source: endpoint(database: "shop", schema: "public"),
            target: endpoint(database: "shop", schema: "archive")
        )

        #expect(refusal != .sameScope)
    }

    @Test
    func aSharedConnectionRefusalKeepsTheComparisonWording() {
        let refusal = ConcurrentReadRefusal.sharedConnection(.duckdb)

        #expect(refusal.comparisonMessage.hasPrefix("DuckDB cannot compare"))
    }

    @Test
    func twoConnectionsAreNeverRefused() {
        let service = CompareRowService()

        #expect(service.concurrentReadRefusal(
                source: endpoint(database: "shop"),
                target: endpoint(database: "shop", connectionId: UUID())
            ) == nil)
    }
}
