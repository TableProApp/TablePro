//
//  DatabaseTreeConnectionStateTests.swift
//  TableProTests
//
//  Per-connection tree metadata registry: each connection observes its own
//  object, so one connection's database/table load cannot invalidate another
//  connection's views.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseTreeConnectionState")
@MainActor
struct DatabaseTreeConnectionStateTests {
    private func objectsKey(_ connectionId: UUID, _ database: String, _ schema: String?) -> DatabaseTreeMetadataService.ObjectsKey {
        DatabaseTreeMetadataService.ObjectsKey(connectionId: connectionId, database: database, schema: schema)
    }

    @Test("forConnection returns the same instance for the same UUID")
    func sameInstanceForSameId() {
        let id = UUID()
        let a = DatabaseTreeConnectionState.forConnection(id)
        let b = DatabaseTreeConnectionState.forConnection(id)
        #expect(a === b)
        DatabaseTreeConnectionState.removeConnection(id)
    }

    @Test("mutating one connection's tables leaves another connection untouched")
    func mutationsAreIsolatedAcrossConnections() {
        let idA = UUID()
        let idB = UUID()
        let a = DatabaseTreeConnectionState.forConnection(idA)
        let b = DatabaseTreeConnectionState.forConnection(idB)

        a.setTablesState(.loaded([TestFixtures.makeTableInfo(name: "users")]), key: objectsKey(idA, "app", nil))

        #expect(b.tablesState.isEmpty)
        #expect(b.databaseList == .idle)

        DatabaseTreeConnectionState.removeConnection(idA)
        DatabaseTreeConnectionState.removeConnection(idB)
    }

    @Test("reset clears state in place, preserving instance identity")
    func resetPreservesInstanceIdentity() {
        let id = UUID()
        let state = DatabaseTreeConnectionState.forConnection(id)
        state.setDatabaseList(.loaded([DatabaseMetadata.minimal(name: "app", isSystem: false)]))
        state.setTablesState(.loaded([TestFixtures.makeTableInfo(name: "users")]), key: objectsKey(id, "app", nil))

        state.reset()

        #expect(state.databaseList == .idle)
        #expect(state.tablesState.isEmpty)
        #expect(DatabaseTreeConnectionState.forConnection(id) === state)

        DatabaseTreeConnectionState.removeConnection(id)
    }

    @Test("removeConnection evicts the instance so a later lookup is fresh")
    func removeConnectionEvicts() {
        let id = UUID()
        let first = DatabaseTreeConnectionState.forConnection(id)
        first.setDatabaseList(.loaded([DatabaseMetadata.minimal(name: "app", isSystem: false)]))

        DatabaseTreeConnectionState.removeConnection(id)
        let second = DatabaseTreeConnectionState.forConnection(id)

        #expect(first !== second)
        #expect(second.databaseList == .idle)

        DatabaseTreeConnectionState.removeConnection(id)
    }
}
