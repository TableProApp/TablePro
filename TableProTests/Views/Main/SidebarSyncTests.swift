//
//  SidebarSyncTests.swift
//  TableProTests
//
//  Tests for SidebarSyncAction — decides whether to sync the sidebar selection
//  when the table list loads in a new window.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SidebarSyncAction")
struct SidebarSyncTests {

    @Test("Tables load, selection empty, current tab has table name — sync")
    func syncsWhenTablesLoadAndSelectionEmpty() {
        let tables = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        let result = SidebarSyncAction.resolveOnTablesLoad(
            newTables: tables,
            selectedTables: [],
            currentTabTableName: "orders"
        )
        #expect(result == .select(tableName: "orders"))
    }

    @Test("Tables load, selection empty, current tab has no table name — no sync")
    func noSyncWhenCurrentTabHasNoTableName() {
        let tables = [TestFixtures.makeTableInfo(name: "users")]
        let result = SidebarSyncAction.resolveOnTablesLoad(
            newTables: tables,
            selectedTables: [],
            currentTabTableName: nil
        )
        #expect(result == .noSync)
    }

    @Test("Tables load, selection already populated — no sync")
    func noSyncWhenSelectionAlreadyPopulated() {
        let tables = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        let selected: Set<TableInfo> = [TestFixtures.makeTableInfo(name: "users")]
        let result = SidebarSyncAction.resolveOnTablesLoad(
            newTables: tables,
            selectedTables: selected,
            currentTabTableName: "orders"
        )
        #expect(result == .noSync)
    }

    @Test("Tables load empty — no sync")
    func noSyncWhenTablesEmpty() {
        let result = SidebarSyncAction.resolveOnTablesLoad(
            newTables: [],
            selectedTables: [],
            currentTabTableName: "users"
        )
        #expect(result == .noSync)
    }

    @Test("Tables load, selection empty, table name not in tables — no sync")
    func noSyncWhenTableNameNotInTables() {
        let tables = [TestFixtures.makeTableInfo(name: "users")]
        let result = SidebarSyncAction.resolveOnTablesLoad(
            newTables: tables,
            selectedTables: [],
            currentTabTableName: "nonexistent"
        )
        #expect(result == .noSync)
    }
}
