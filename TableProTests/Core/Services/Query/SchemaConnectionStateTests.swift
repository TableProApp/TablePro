//
//  SchemaConnectionStateTests.swift
//  TableProTests
//
//  Per-connection schema state registry: each connection observes its own
//  object so one connection's load cannot invalidate another's views, and a
//  routines load cannot invalidate the table list.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SchemaConnectionState")
@MainActor
struct SchemaConnectionStateTests {
    private func routine(_ name: String) -> RoutineInfo {
        RoutineInfo(name: name, schema: nil, kind: .procedure, signature: nil)
    }

    @Test("forConnection returns the same instance for the same UUID")
    func sameInstanceForSameId() {
        let id = UUID()
        let a = SchemaConnectionState.forConnection(id)
        let b = SchemaConnectionState.forConnection(id)
        #expect(a === b)
        SchemaConnectionState.removeConnection(id)
    }

    @Test("forConnection returns different instances for different UUIDs")
    func differentInstanceForDifferentId() {
        let id1 = UUID()
        let id2 = UUID()
        let a = SchemaConnectionState.forConnection(id1)
        let b = SchemaConnectionState.forConnection(id2)
        #expect(a !== b)
        SchemaConnectionState.removeConnection(id1)
        SchemaConnectionState.removeConnection(id2)
    }

    @Test("mutating one connection does not change another's revisions or state")
    func mutationsAreIsolatedAcrossConnections() {
        let idA = UUID()
        let idB = UUID()
        let a = SchemaConnectionState.forConnection(idA)
        let b = SchemaConnectionState.forConnection(idB)
        let bTablesRevision = b.tablesRevision
        let bRoutinesRevision = b.routinesRevision

        a.setState(.loaded([TestFixtures.makeTableInfo(name: "users")]))
        a.setProcedures([routine("do_thing")])

        #expect(b.tablesRevision == bTablesRevision)
        #expect(b.routinesRevision == bRoutinesRevision)
        #expect(b.state == .idle)

        SchemaConnectionState.removeConnection(idA)
        SchemaConnectionState.removeConnection(idB)
    }

    @Test("a routines load bumps only the routines revision, never the tables revision")
    func routineLoadDoesNotInvalidateTables() {
        let id = UUID()
        let state = SchemaConnectionState.forConnection(id)
        state.setState(.loaded([TestFixtures.makeTableInfo(name: "users")]))
        let tablesRevisionAfterLoad = state.tablesRevision
        let routinesRevisionBefore = state.routinesRevision

        state.setProcedures([routine("a")])
        state.setFunctions([routine("b")])

        #expect(state.tablesRevision == tablesRevisionAfterLoad)
        #expect(state.routinesRevision > routinesRevisionBefore)

        SchemaConnectionState.removeConnection(id)
    }

    @Test("a tables load bumps only the tables revision, never the routines revision")
    func tableLoadDoesNotInvalidateRoutines() {
        let id = UUID()
        let state = SchemaConnectionState.forConnection(id)
        state.setProcedures([routine("a")])
        let routinesRevisionAfterLoad = state.routinesRevision
        let tablesRevisionBefore = state.tablesRevision

        state.setState(.loaded([TestFixtures.makeTableInfo(name: "users")]))

        #expect(state.routinesRevision == routinesRevisionAfterLoad)
        #expect(state.tablesRevision > tablesRevisionBefore)

        SchemaConnectionState.removeConnection(id)
    }

    @Test("reset returns the state to idle in place, preserving instance identity")
    func resetPreservesInstanceIdentity() {
        let id = UUID()
        let state = SchemaConnectionState.forConnection(id)
        state.setState(.loaded([TestFixtures.makeTableInfo(name: "users")]))

        state.reset()

        #expect(state.state == .idle)
        #expect(SchemaConnectionState.forConnection(id) === state)

        SchemaConnectionState.removeConnection(id)
    }

    @Test("removeConnection evicts the instance so a later lookup is fresh")
    func removeConnectionEvicts() {
        let id = UUID()
        let first = SchemaConnectionState.forConnection(id)
        first.setState(.loaded([TestFixtures.makeTableInfo(name: "users")]))

        SchemaConnectionState.removeConnection(id)
        let second = SchemaConnectionState.forConnection(id)

        #expect(first !== second)
        #expect(second.state == .idle)

        SchemaConnectionState.removeConnection(id)
    }
}
