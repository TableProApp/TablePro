//
//  TableSelectionChangeTests.swift
//  TableProTests
//
//  Tests for TableSelectionAction — the pure decision logic that determines
//  whether a sidebar selection change should trigger table navigation.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("TableSelectionAction")
struct TableSelectionChangeTests {

    // MARK: - Single click (exactly one table added)

    @Test("Single click adds one table — navigate to it")
    func singleClickNavigates() {
        let old: Set<DatabaseTreeTableRef> = []
        let new: Set<DatabaseTreeTableRef> = [TestFixtures.makeTableRef(name: "orders")]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "orders", type: .table)))
    }

    @Test("Single click on a view — navigate with isView true")
    func singleClickOnView() {
        let old: Set<DatabaseTreeTableRef> = []
        let view = TestFixtures.makeTableRef(name: "my_view", type: .view)
        let new: Set<DatabaseTreeTableRef> = [view]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "my_view", type: .view)))
    }

    @Test("Cmd+click extends the selection without opening the table it added")
    func cmdClickAddsOneMore() {
        let existing = TestFixtures.makeTableRef(name: "users")
        let added = TestFixtures.makeTableRef(name: "orders")
        let old: Set<DatabaseTreeTableRef> = [existing]
        let new: Set<DatabaseTreeTableRef> = [existing, added]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    @Test("Narrowing a multi-selection back to one table does not reopen it")
    func narrowingToAPreviouslySelectedTableDoesNotNavigate() {
        let kept = TestFixtures.makeTableRef(name: "users")
        let old: Set<DatabaseTreeTableRef> = [kept, TestFixtures.makeTableRef(name: "orders")]
        let new: Set<DatabaseTreeTableRef> = [kept]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    // MARK: - Multi-selection (Cmd+A, Shift+click)

    @Test("Cmd+A adds many tables — no navigation")
    func cmdANoNavigation() {
        let old: Set<DatabaseTreeTableRef> = []
        let new: Set<DatabaseTreeTableRef> = [
            TestFixtures.makeTableRef(name: "users"),
            TestFixtures.makeTableRef(name: "orders"),
            TestFixtures.makeTableRef(name: "products")
        ]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    @Test("Shift+click adds multiple tables — no navigation")
    func shiftClickNoNavigation() {
        let existing = TestFixtures.makeTableRef(name: "users")
        let old: Set<DatabaseTreeTableRef> = [existing]
        let new: Set<DatabaseTreeTableRef> = [
            existing,
            TestFixtures.makeTableRef(name: "orders"),
            TestFixtures.makeTableRef(name: "products")
        ]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    // MARK: - Deselection

    @Test("Deselect tables (none added) — no navigation")
    func deselectNoNavigation() {
        let old: Set<DatabaseTreeTableRef> = [
            TestFixtures.makeTableRef(name: "users"),
            TestFixtures.makeTableRef(name: "orders")
        ]
        let new: Set<DatabaseTreeTableRef> = [TestFixtures.makeTableRef(name: "users")]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    @Test("Deselect all — no navigation")
    func deselectAllNoNavigation() {
        let old: Set<DatabaseTreeTableRef> = [TestFixtures.makeTableRef(name: "users")]
        let new: Set<DatabaseTreeTableRef> = []
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    // MARK: - No change

    @Test("No change (same set) — no navigation")
    func noChangeNoNavigation() {
        let tables: Set<DatabaseTreeTableRef> = [TestFixtures.makeTableRef(name: "users")]
        let action = TableSelectionAction.resolve(oldTables: tables, newTables: tables, selectedRowCount: tables.count)
        #expect(action == .noNavigation)
    }

    @Test("Empty to empty gives no navigation")
    func emptyToEmptyNoNavigation() {
        let action = TableSelectionAction.resolve(oldTables: [], newTables: [], selectedRowCount: 0)
        #expect(action == .noNavigation)
    }

    /// The object tree can select a row that is not a table. One table selected alongside a schema
    /// yields exactly one table, so the table set alone reads it as a fresh pick; the row count is
    /// what tells the two apart.
    @Test("A table selected alongside a non-table row is an extension, not a pick")
    func aTableBesideAnotherRowDoesNotNavigate() {
        let new: Set<DatabaseTreeTableRef> = [TestFixtures.makeTableRef(name: "orders")]
        let action = TableSelectionAction.resolve(oldTables: [], newTables: new, selectedRowCount: 2)
        #expect(action == .noNavigation)
    }
}
