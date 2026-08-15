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
        let old: Set<TableInfo> = []
        let new: Set<TableInfo> = [TestFixtures.makeTableInfo(name: "orders")]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .navigate(table: TableInfo(name: "orders", type: .table, rowCount: nil)))
    }

    @Test("Single click on a view — navigate with isView true")
    func singleClickOnView() {
        let old: Set<TableInfo> = []
        let view = TableInfo(name: "my_view", type: .view, rowCount: nil)
        let new: Set<TableInfo> = [view]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .navigate(table: TableInfo(name: "my_view", type: .view, rowCount: nil)))
    }

    @Test("Cmd+click extends the selection without opening the table it added")
    func cmdClickAddsOneMore() {
        let existing = TestFixtures.makeTableInfo(name: "users")
        let added = TestFixtures.makeTableInfo(name: "orders")
        let old: Set<TableInfo> = [existing]
        let new: Set<TableInfo> = [existing, added]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    @Test("Narrowing a multi-selection back to one table does not reopen it")
    func narrowingToAPreviouslySelectedTableDoesNotNavigate() {
        let kept = TestFixtures.makeTableInfo(name: "users")
        let old: Set<TableInfo> = [kept, TestFixtures.makeTableInfo(name: "orders")]
        let new: Set<TableInfo> = [kept]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    // MARK: - Multi-selection (Cmd+A, Shift+click)

    @Test("Cmd+A adds many tables — no navigation")
    func cmdANoNavigation() {
        let old: Set<TableInfo> = []
        let new: Set<TableInfo> = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "products")
        ]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    @Test("Shift+click adds multiple tables — no navigation")
    func shiftClickNoNavigation() {
        let existing = TestFixtures.makeTableInfo(name: "users")
        let old: Set<TableInfo> = [existing]
        let new: Set<TableInfo> = [
            existing,
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "products")
        ]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    // MARK: - Deselection

    @Test("Deselect tables (none added) — no navigation")
    func deselectNoNavigation() {
        let old: Set<TableInfo> = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        let new: Set<TableInfo> = [TestFixtures.makeTableInfo(name: "users")]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    @Test("Deselect all — no navigation")
    func deselectAllNoNavigation() {
        let old: Set<TableInfo> = [TestFixtures.makeTableInfo(name: "users")]
        let new: Set<TableInfo> = []
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation)
    }

    // MARK: - No change

    @Test("No change (same set) — no navigation")
    func noChangeNoNavigation() {
        let tables: Set<TableInfo> = [TestFixtures.makeTableInfo(name: "users")]
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
        let new: Set<TableInfo> = [TestFixtures.makeTableInfo(name: "orders")]
        let action = TableSelectionAction.resolve(oldTables: [], newTables: new, selectedRowCount: 2)
        #expect(action == .noNavigation)
    }
}
