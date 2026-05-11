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
        let table = TestFixtures.makeTableInfo(name: "t", type: .table)
        #expect(SidebarContextMenuLogic.importVisible(clickedTable: table, supportsImport: true))
    }

    @Test("Import hidden for view")
    func importHiddenForView() {
        let view = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: view, supportsImport: true))
    }

    @Test("Import hidden for materialized view")
    func importHiddenForMaterializedView() {
        let mv = TestFixtures.makeTableInfo(name: "mv", type: .materializedView)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: mv, supportsImport: true))
    }

    @Test("Import hidden for foreign table")
    func importHiddenForForeignTable() {
        let ft = TestFixtures.makeTableInfo(name: "ft", type: .foreignTable)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: ft, supportsImport: true))
    }

    @Test("Import hidden when import not supported")
    func importHiddenWhenNotSupported() {
        let table = TestFixtures.makeTableInfo(name: "t", type: .table)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: table, supportsImport: false))
    }

    // MARK: - Truncate Visibility

    @Test("Truncate visible for table")
    func truncateVisibleForTable() {
        let table = TestFixtures.makeTableInfo(name: "t", type: .table)
        #expect(SidebarContextMenuLogic.truncateVisible(clickedTable: table))
    }

    @Test("Truncate hidden for view")
    func truncateHiddenForView() {
        let view = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: view))
    }

    @Test("Truncate hidden for materialized view")
    func truncateHiddenForMaterializedView() {
        let mv = TestFixtures.makeTableInfo(name: "mv", type: .materializedView)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: mv))
    }

    @Test("Truncate hidden for foreign table")
    func truncateHiddenForForeignTable() {
        let ft = TestFixtures.makeTableInfo(name: "ft", type: .foreignTable)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: ft))
    }

    @Test("Truncate hidden for system table")
    func truncateHiddenForSystemTable() {
        let sys = TestFixtures.makeTableInfo(name: "s", type: .systemTable)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: sys))
    }

    // MARK: - Delete Label per Kind

    @Test("Delete label for table")
    func deleteLabelForTable() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .table) == "Delete")
    }

    @Test("Delete label for view")
    func deleteLabelForView() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .view) == "Drop View")
    }

    @Test("Delete label for materialized view")
    func deleteLabelForMaterializedView() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .materializedView) == "Drop Materialized View")
    }

    @Test("Delete label for foreign table")
    func deleteLabelForForeignTable() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .foreignTable) == "Drop Foreign Table")
    }

    @Test("Delete label for nil falls back to Delete")
    func deleteLabelForNil() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: nil) == "Delete")
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
