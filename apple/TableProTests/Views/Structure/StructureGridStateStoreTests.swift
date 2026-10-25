//
//  StructureGridStateStoreTests.swift
//  TableProTests
//
//  D1: the Structure grid used to save its column widths under the table's own key, over the Data tab's layout.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureGridStateStoreTests {
    private func makeSession(table: String = "orders_\(UUID().uuidString.prefix(8))") -> StructureEditingSession {
        let session = StructureEditingSession(
            identity: "shop.\(table)",
            connection: TestFixtures.makeConnection(database: "shop", type: .mysql),
            databaseName: "shop",
            schemaName: nil,
            tableName: table
        )
        session.changeManager.loadSchema(
            tableName: table,
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "total", dataType: "DECIMAL(10,2)", isNullable: true, isPrimaryKey: false),
            ],
            indexes: [IndexInfo(name: "ix_total", columns: ["total"], isUnique: false, isPrimary: false, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        session.gridAdapter.refresh()
        return session
    }

    private func nameHeading(_ session: StructureEditingSession) throws -> String {
        try #require(session.gridModel.columns.column(at: 0)).name
    }

    @Test("A column resized in the Structure grid stays on the session and never reaches the table's saved layout")
    func resizeNeverWritesTheTableLayout() throws {
        let session = makeSession()
        let model = session.gridModel
        let name = try nameHeading(session)
        let tableKey = ColumnLayoutTableKey(
            connectionId: session.connection.id,
            databaseName: "shop",
            schemaName: nil,
            tableName: session.tableName
        )

        model.columnGeometryDidChange(widths: [name: 260], order: nil)

        #expect(model.store.layoutScope == .ephemeral)
        #expect(session.columnLayouts[.columns]?.columnWidths[name] == 260)
        #expect(model.store.columnLayout.columnWidths[name] == 260)
        #expect(FileColumnLayoutPersister.shared.load(for: tableKey) == nil)
    }

    @Test("Each sub-tab keeps its own column layout")
    func layoutIsPerSubTab() throws {
        let session = makeSession()
        let model = session.gridModel
        let name = try nameHeading(session)
        model.columnGeometryDidChange(widths: [name: 260], order: nil)

        session.selectedTab = .indexes
        session.gridAdapter.refresh()
        #expect(model.store.columnLayout.columnWidths[name] == nil)
        model.columnGeometryDidChange(widths: [name: 180], order: nil)

        session.selectedTab = .columns
        session.gridAdapter.refresh()
        #expect(model.store.columnLayout.columnWidths[name] == 260)
        #expect(session.columnLayouts[.indexes]?.columnWidths[name] == 180)
    }

    @Test("Another sub-tab starts with no value filter and no selection")
    func subTabSwitchStartsTheViewOver() throws {
        let session = makeSession()
        let model = session.gridModel
        let name = try nameHeading(session)
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["id"], includesNull: false), columnName: name, forColumn: 0)
        model.setValueFilter(filter)
        model.selectRows([StructureRowProvider.rowID(forSourceIndex: 0)])
        #expect(model.store.valueFilter.isActive)
        #expect(!model.selection.isEmpty)

        session.selectedTab = .indexes
        session.gridAdapter.refresh()

        #expect(!model.store.valueFilter.isActive)
        #expect(model.store.selectionSnapshot.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(model.rowCount == 1)
    }

    @Test("The sort lives on the session, which is what orders the provider's rows")
    func sortLivesOnTheSession() {
        let session = makeSession()
        let model = session.gridModel
        let descending = SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user)

        model.setSort(descending)

        #expect(session.sortState == descending)
        #expect(session.sortDescriptor?.column == 0)
        #expect(session.sortDescriptor?.ascending == false)
        #expect(model.rows.rows.compactMap { $0.values.first?.asText } == ["total", "id"])
    }

    // The provider sorts by one key, so a secondary key the header appended is dropped (changed on purpose).
    @Test("A secondary sort key is dropped, since the provider sorts by one column")
    func secondarySortKeyIsDropped() {
        let session = makeSession()
        let model = session.gridModel
        let primary = SortColumn(columnIndex: 1, direction: .ascending)

        model.setSort(SortState(columns: [primary, SortColumn(columnIndex: 0, direction: .descending)], source: .user))

        #expect(session.sortState.columns == [primary])
        #expect(model.store.sortState.columns == [primary])
    }

    @Test("Create Table's grid is ephemeral too")
    func createTableIsEphemeral() {
        let adapter = CreateTableGridAdapter(
            structureChangeManager: StructureChangeManager(),
            connection: TestFixtures.makeConnection(type: .postgresql)
        )
        adapter.refresh()

        #expect(adapter.model.store.layoutScope == .ephemeral)
    }
}
