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
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new)
        #expect(action == .navigate(tableName: "orders", isView: false))
    }

    @Test("Single click on a view — navigate with isView true")
    func singleClickOnView() {
        let old: Set<TableInfo> = []
        let view = TableInfo(name: "my_view", type: .view, rowCount: nil)
        let new: Set<TableInfo> = [view]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new)
        #expect(action == .navigate(tableName: "my_view", isView: true))
    }

    @Test("Cmd+click adds exactly one more table — navigate to it")
    func cmdClickAddsOneMore() {
        let existing = TestFixtures.makeTableInfo(name: "users")
        let added = TestFixtures.makeTableInfo(name: "orders")
        let old: Set<TableInfo> = [existing]
        let new: Set<TableInfo> = [existing, added]
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new)
        #expect(action == .navigate(tableName: "orders", isView: false))
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
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new)
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
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new)
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
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new)
        #expect(action == .noNavigation)
    }

    @Test("Deselect all — no navigation")
    func deselectAllNoNavigation() {
        let old: Set<TableInfo> = [TestFixtures.makeTableInfo(name: "users")]
        let new: Set<TableInfo> = []
        let action = TableSelectionAction.resolve(oldTables: old, newTables: new)
        #expect(action == .noNavigation)
    }

    // MARK: - No change

    @Test("No change (same set) — no navigation")
    func noChangeNoNavigation() {
        let tables: Set<TableInfo> = [TestFixtures.makeTableInfo(name: "users")]
        let action = TableSelectionAction.resolve(oldTables: tables, newTables: tables)
        #expect(action == .noNavigation)
    }

    @Test("Empty to empty — no navigation")
    func emptyToEmptyNoNavigation() {
        let action = TableSelectionAction.resolve(oldTables: [], newTables: [])
        #expect(action == .noNavigation)
    }
}
