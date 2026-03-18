//
//  SidebarContextMenuLogicTests.swift
//  TableProTests
//
//  Tests for SidebarContextMenu computed property logic extracted into SidebarContextMenuLogic.
//

import SwiftUI
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SidebarContextMenuLogicTests")
struct SidebarContextMenuLogicTests {

    // MARK: - hasSelection

    @Test("hasSelection false when empty selection and no clicked table")
    func hasSelectionEmpty() {
        #expect(!SidebarContextMenuLogic.hasSelection(selectedTables: [], clickedTable: nil))
    }

    @Test("hasSelection true when clicked table exists")
    func hasSelectionClickedOnly() {
        let table = TestFixtures.makeTableInfo(name: "users")
        #expect(SidebarContextMenuLogic.hasSelection(selectedTables: [], clickedTable: table))
    }

    @Test("hasSelection true when selection exists")
    func hasSelectionSelectedOnly() {
        let table = TestFixtures.makeTableInfo(name: "users")
        #expect(SidebarContextMenuLogic.hasSelection(selectedTables: [table], clickedTable: nil))
    }

    @Test("hasSelection true when both exist")
    func hasSelectionBoth() {
        let t1 = TestFixtures.makeTableInfo(name: "users")
        let t2 = TestFixtures.makeTableInfo(name: "orders")
        #expect(SidebarContextMenuLogic.hasSelection(selectedTables: [t1], clickedTable: t2))
    }

    // MARK: - isView

    @Test("isView true for view type")
    func isViewTrue() {
        let view = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(SidebarContextMenuLogic.isView(clickedTable: view))
    }

    @Test("isView false for table type")
    func isViewFalseForTable() {
        let table = TestFixtures.makeTableInfo(name: "t", type: .table)
        #expect(!SidebarContextMenuLogic.isView(clickedTable: table))
    }

    @Test("isView false for nil")
    func isViewFalseForNil() {
        #expect(!SidebarContextMenuLogic.isView(clickedTable: nil))
    }

    // MARK: - Import Visibility

    @Test("Import visible for table with import support")
    func importVisibleForTable() {
        #expect(SidebarContextMenuLogic.importVisible(isView: false, supportsImport: true))
    }

    @Test("Import hidden for view")
    func importHiddenForView() {
        #expect(!SidebarContextMenuLogic.importVisible(isView: true, supportsImport: true))
    }

    @Test("Import hidden when import not supported")
    func importHiddenWhenNotSupported() {
        #expect(!SidebarContextMenuLogic.importVisible(isView: false, supportsImport: false))
    }

    // MARK: - Truncate Visibility

    @Test("Truncate visible for table")
    func truncateVisibleForTable() {
        #expect(SidebarContextMenuLogic.truncateVisible(isView: false))
    }

    @Test("Truncate hidden for view")
    func truncateHiddenForView() {
        #expect(!SidebarContextMenuLogic.truncateVisible(isView: true))
    }

    // MARK: - Delete Label

    @Test("Delete label for table")
    func deleteLabelForTable() {
        #expect(SidebarContextMenuLogic.deleteLabel(isView: false) == "Delete")
    }

    @Test("Delete label for view")
    func deleteLabelForView() {
        #expect(SidebarContextMenuLogic.deleteLabel(isView: true) == "Drop View")
    }

    // MARK: - Disabled State Combinations

    @Test("Copy name disabled with no selection")
    func copyNameDisabledNoSelection() {
        let hasSelection = SidebarContextMenuLogic.hasSelection(selectedTables: [], clickedTable: nil)
        #expect(!hasSelection)
    }

    @Test("Copy name enabled with selection")
    func copyNameEnabledWithSelection() {
        let table = TestFixtures.makeTableInfo(name: "users")
        let hasSelection = SidebarContextMenuLogic.hasSelection(selectedTables: [table], clickedTable: nil)
        #expect(hasSelection)
    }

    @Test("Show structure disabled when clicked table is nil")
    func showStructureDisabledNilTable() {
        let clickedTable: TableInfo? = nil
        #expect(clickedTable == nil)
    }

    @Test("Show structure enabled when clicked table exists")
    func showStructureEnabledWithTable() {
        let clickedTable: TableInfo? = TestFixtures.makeTableInfo(name: "users")
        #expect(clickedTable != nil)
    }
}
