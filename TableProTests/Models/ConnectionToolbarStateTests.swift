//
//  ConnectionToolbarStateTests.swift
//  TableProTests
//
//  Tests for the toolbar chip's grouping-aware text resolution.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("ConnectionToolbarState")
struct ConnectionToolbarStateTests {
    // MARK: - chipText

    @Test("chipText returns currentDatabase when grouping is byDatabase")
    func chipTextByDatabase() {
        let state = ConnectionToolbarState()
        state.databaseGroupingStrategy = .byDatabase
        state.currentDatabase = "myappdb"
        state.currentSchema = "ignored"

        #expect(state.chipText == "myappdb")
    }

    @Test("chipText returns currentSchema when grouping is bySchema and schema is set")
    func chipTextBySchemaWithSchema() {
        let state = ConnectionToolbarState()
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = "dbo"

        #expect(state.chipText == "dbo")
    }

    @Test("chipText falls back to currentDatabase when grouping is bySchema and schema is nil")
    func chipTextBySchemaWithNilSchema() {
        let state = ConnectionToolbarState()
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = nil

        #expect(state.chipText == "Sales")
    }

    @Test("chipText falls back to currentDatabase when grouping is bySchema and schema is empty")
    func chipTextBySchemaWithEmptySchema() {
        let state = ConnectionToolbarState()
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = ""

        #expect(state.chipText == "Sales")
    }

    @Test("chipText returns currentDatabase when grouping is flat (Redis, MongoDB)")
    func chipTextFlat() {
        let state = ConnectionToolbarState()
        state.databaseGroupingStrategy = .flat
        state.currentDatabase = "0"
        state.currentSchema = "ignored"

        #expect(state.chipText == "0")
    }

    // MARK: - reset

    @Test("reset clears database, schema, and grouping strategy")
    func resetClearsAllChipFields() {
        let state = ConnectionToolbarState()
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = "dbo"

        state.reset()

        #expect(state.currentDatabase == "")
        #expect(state.currentSchema == nil)
        #expect(state.databaseGroupingStrategy == .byDatabase)
        #expect(state.chipText == "")
    }

    // MARK: - syncFromSession

    @Test("syncFromSession resolves currentDatabase from connection when no session exists")
    func syncFromSessionFallsBackToConnectionDatabase() {
        let connection = TestFixtures.makeConnection(database: "Production", type: .postgresql)
        let state = ConnectionToolbarState()

        state.syncFromSession(for: connection)

        #expect(state.currentDatabase == "Production")
    }
}
