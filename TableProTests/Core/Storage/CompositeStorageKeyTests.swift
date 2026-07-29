//
//  CompositeStorageKeyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CompositeStorageKey")
struct CompositeStorageKeyTests {
    @Test("Distinct database/schema/table scopes produce distinct keys")
    func distinctScopesDiffer() {
        let connectionId = UUID()
        let publicUsers = CompositeStorageKey.make(
            connectionId: connectionId, databaseName: "app", schemaName: "public", tableName: "users"
        )
        let authUsers = CompositeStorageKey.make(
            connectionId: connectionId, databaseName: "app", schemaName: "auth", tableName: "users"
        )
        #expect(publicUsers != authUsers)
    }

    @Test("Dots in component names do not collide because components are percent-encoded")
    func dotsDoNotCollide() {
        let connectionId = UUID()
        let dbWithDot = CompositeStorageKey.make(
            connectionId: connectionId, databaseName: "a.b", schemaName: nil, tableName: "c"
        )
        let schemaSplit = CompositeStorageKey.make(
            connectionId: connectionId, databaseName: "a", schemaName: "b", tableName: "c"
        )
        #expect(dbWithDot != schemaSplit)
    }

    @Test("Same scope produces a stable key")
    func stableForSameScope() {
        let connectionId = UUID()
        let first = CompositeStorageKey.make(
            connectionId: connectionId, databaseName: "app", schemaName: "public", tableName: "users"
        )
        let second = CompositeStorageKey.make(
            connectionId: connectionId, databaseName: "app", schemaName: "public", tableName: "users"
        )
        #expect(first == second)
    }
}
