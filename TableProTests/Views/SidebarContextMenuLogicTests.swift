//
//  SidebarContextMenuLogicTests.swift
//  TableProTests
//
//  Tests for SidebarContextMenu computed property logic extracted into SidebarContextMenuLogic.
//

import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

struct SidebarContextMenuLogicTests {
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
        #expect(SidebarContextMenuLogic.truncateVisible(targets: [Self.ref(table)], context: Self.expressible([Self.ref(table)])))
    }

    @Test("Truncate hidden for view")
    func truncateHiddenForView() {
        let view = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(!SidebarContextMenuLogic.truncateVisible(targets: [Self.ref(view)], context: Self.expressible([Self.ref(view)])))
    }

    @Test("Truncate hidden for materialized view")
    func truncateHiddenForMaterializedView() {
        let mv = TestFixtures.makeTableInfo(name: "mv", type: .materializedView)
        #expect(!SidebarContextMenuLogic.truncateVisible(targets: [Self.ref(mv)], context: Self.expressible([Self.ref(mv)])))
    }

    @Test("Truncate hidden for foreign table")
    func truncateHiddenForForeignTable() {
        let ft = TestFixtures.makeTableInfo(name: "ft", type: .foreignTable)
        #expect(!SidebarContextMenuLogic.truncateVisible(targets: [Self.ref(ft)], context: Self.expressible([Self.ref(ft)])))
    }

    @Test("Truncate hidden for system table")
    func truncateHiddenForSystemTable() {
        let sys = TestFixtures.makeTableInfo(name: "s", type: .systemTable)
        #expect(!SidebarContextMenuLogic.truncateVisible(targets: [Self.ref(sys)], context: Self.expressible([Self.ref(sys)])))
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

    // MARK: - Maintenance group disabled rule

    private func operation(_ name: String) -> PluginMaintenanceOperation {
        PluginMaintenanceOperation(name: name, appliesTo: [.table], scope: .object)
    }

    @Test("Maintenance group enabled with selection, writable, and applicable ops")
    func maintenanceEnabledAllConditions() {
        #expect(SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: false,
            hasSelection: true,
            applicableOperations: [operation("ANALYZE"), operation("OPTIMIZE")]
        ))
    }

    @Test("Maintenance group disabled when read-only")
    func maintenanceDisabledReadOnly() {
        #expect(!SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: true,
            hasSelection: true,
            applicableOperations: [operation("ANALYZE")]
        ))
    }

    @Test("Maintenance group disabled with no selection")
    func maintenanceDisabledNoSelection() {
        #expect(!SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: false,
            hasSelection: false,
            applicableOperations: [operation("ANALYZE")]
        ))
    }

    @Test("Maintenance group disabled when nothing the driver offers applies to the clicked object")
    func maintenanceDisabledNoOps() {
        #expect(!SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: false,
            hasSelection: true,
            applicableOperations: []
        ))
    }

    // MARK: - External Tables

    @Test("External table counts as a read-only kind")
    func externalTableIsReadOnlyKind() {
        #expect(SidebarContextMenuLogic.isReadOnlyKind(.externalTable))
    }

    @Test("Import is hidden for an external table")
    func importHiddenForExternalTable() {
        let table = TableInfo(name: "customers", type: .externalTable, rowCount: nil)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: table, supportsImport: true))
    }

    @Test("Truncate is hidden for an external table")
    func truncateHiddenForExternalTable() {
        let table = TableInfo(name: "customers", type: .externalTable, rowCount: nil)
        #expect(!SidebarContextMenuLogic.truncateVisible(targets: [Self.ref(table)], context: Self.expressible([Self.ref(table)])))
    }

    @Test("External table drop label names the object kind")
    func externalTableDeleteLabel() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .externalTable) == "Drop External Table")
    }

    // MARK: - Sequences

    /// Measured on MariaDB 11.4.13: a sequence refuses UPDATE, DELETE and TRUNCATE with ERROR 1031,
    /// and `DROP SEQUENCE` is the statement that removes one.
    @Test("A sequence is read-only, offers no Import or Truncate, and drops as a sequence")
    func sequenceIsReadOnly() {
        let table = TableInfo(name: "order_ids", type: .sequence, rowCount: nil)

        #expect(SidebarContextMenuLogic.isReadOnlyKind(.sequence))
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: table, supportsImport: true))
        #expect(!SidebarContextMenuLogic.truncateVisible(
            targets: [Self.ref(table)], context: Self.expressible([Self.ref(table)])
        ))
        #expect(SidebarContextMenuLogic.deleteLabel(for: .sequence) == "Drop Sequence")
    }

    /// The predicate now answers for every row a Truncate would act on, so the tests build refs.
    private static func ref(_ table: TableInfo) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(database: "app", schema: "public", table: table)
    }

    /// An engine that has a truncate statement for everything asked about, so these cases keep
    /// testing the object-kind rule rather than the engine one.
    private static func expressible(
        _ targets: [DatabaseTreeTableRef]
    ) -> TableOperationEligibility.Context {
        TableOperationEligibility.Context(
            droppable: Set(targets), truncatable: Set(targets), isReadOnly: false
        )
    }

    @Test("Truncate is hidden when a selection mixes a table with a view")
    func truncateHiddenForMixedSelection() {
        let table = TableInfo(name: "orders", type: .table, rowCount: nil)
        let view = TableInfo(name: "summary", type: .view, rowCount: nil)
        #expect(!SidebarContextMenuLogic.truncateVisible(targets: [Self.ref(table), Self.ref(view)], context: Self.expressible([Self.ref(table), Self.ref(view)])))
    }

    /// #2884: the engine gate is the other half. Elasticsearch has an index, which is a
    /// truncatable kind, and no statement to truncate it with.
    @Test("Truncate is hidden when the engine has no statement for it")
    func truncateHiddenWhenEngineCannotExpressIt() {
        let table = TableInfo(name: "test_index", type: .table, rowCount: nil)
        #expect(!SidebarContextMenuLogic.truncateVisible(
            targets: [Self.ref(table)],
            context: TableOperationEligibility.Context(droppable: [], truncatable: [], isReadOnly: false)
        ))
    }

    @Test("Truncate is hidden for an empty selection")
    func truncateHiddenForEmptySelection() {
        #expect(!SidebarContextMenuLogic.truncateVisible(targets: [DatabaseTreeTableRef](), context: Self.expressible([DatabaseTreeTableRef]())))
    }
}
