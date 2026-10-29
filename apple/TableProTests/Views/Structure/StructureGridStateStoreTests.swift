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
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeEditor(table: String = "orders_\(UUID().uuidString.prefix(8))") -> StructureDefinitionEditor {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: table,
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "total", dataType: "DECIMAL(10,2)", isNullable: true, isPrimaryKey: false),
            ],
            indexes: [IndexInfo(name: "ix_total", columns: ["total"], isUnique: false, isPrimary: false, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .existingTable(
                connection: TestFixtures.makeConnection(database: "shop", type: .mysql),
                databaseName: "shop",
                schemaName: nil,
                tableName: table,
                objectKind: .table,
                isSessionBound: false
            ),
            defaults: suite.defaults
        )
        editor.refresh()
        return editor
    }

    private func nameHeading(_ model: DataGridModel) throws -> String {
        try #require(model.columns.column(at: 0)).name
    }

    @Test("A column resized in a section's grid stays on its store and never reaches the table's saved layout")
    func resizeNeverWritesTheTableLayout() throws {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        let model = adapter.model
        let name = try nameHeading(model)
        let tableKey = ColumnLayoutTableKey(
            connectionId: editor.context.connection.id,
            databaseName: "shop",
            schemaName: nil,
            tableName: editor.context.tableName
        )

        model.columnGeometryDidChange(widths: [name: 260], order: nil)

        #expect(model.store.layoutScope == .ephemeral)
        #expect(adapter.store.columnLayout.columnWidths[name] == 260)
        #expect(FileColumnLayoutPersister.shared.load(for: tableKey) == nil)
    }

    @Test("Each section keeps its own column layout")
    func layoutIsPerSection() throws {
        let editor = makeEditor()
        let columns = editor.adapter(for: .columns)
        let indexes = editor.adapter(for: .indexes)
        let name = try nameHeading(columns.model)

        columns.model.columnGeometryDidChange(widths: [name: 260], order: nil)
        #expect(indexes.store.columnLayout.columnWidths[name] == nil)
        indexes.model.columnGeometryDidChange(widths: [name: 180], order: nil)

        #expect(columns.store.columnLayout.columnWidths[name] == 260)
        #expect(indexes.store.columnLayout.columnWidths[name] == 180)
    }

    @Test("A value filter in one section leaves the others unfiltered")
    func valueFilterIsPerSection() throws {
        let editor = makeEditor()
        let columns = editor.adapter(for: .columns)
        let indexes = editor.adapter(for: .indexes)
        let name = try nameHeading(columns.model)
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["id"], includesNull: false), columnName: name, forColumn: 0)

        columns.model.setValueFilter(filter)
        editor.refresh()

        #expect(columns.store.valueFilter.isActive)
        #expect(columns.model.rowCount == 1)
        #expect(!indexes.store.valueFilter.isActive)
        #expect(indexes.model.rowCount == 1)
    }

    @Test("The sort lives on the section's store, which is what orders the provider's rows")
    func sortLivesOnTheSectionStore() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        let model = adapter.model
        let descending = SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user)

        model.setSort(descending)

        #expect(adapter.store.sortState == descending)
        #expect(model.rows.rows.compactMap { $0.values.first?.asText } == ["total", "id"])
        #expect(editor.adapter(for: .indexes).store.sortState.columns.isEmpty)
    }

    @Test("A sort survives a refresh of the definitions")
    func sortSurvivesRefresh() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        adapter.model.setSort(SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user))

        var amount = EditableColumnDefinition.placeholder()
        amount.name = "amount"
        amount.dataType = "INT"
        editor.manager.addColumn(amount)
        editor.refresh()

        #expect(adapter.model.rows.rows.compactMap { $0.values.first?.asText } == ["total", "id", "amount"])
    }

    // The provider sorts by one key, so a secondary key the header appended is dropped (changed on purpose).
    @Test("A secondary sort key is dropped, since the provider sorts by one column")
    func secondarySortKeyIsDropped() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        let primary = SortColumn(columnIndex: 1, direction: .ascending)

        adapter.model.setSort(SortState(columns: [primary, SortColumn(columnIndex: 0, direction: .descending)], source: .user))

        #expect(adapter.store.sortState.columns == [primary])
        #expect(adapter.model.store.sortState.columns == [primary])
    }

    @Test("Create Table's grids are ephemeral too")
    func createTableIsEphemeral() {
        let editor = StructureDefinitionEditor(
            manager: StructureChangeManager(),
            context: .newTable(connection: TestFixtures.makeConnection(type: .postgresql), databaseName: "shop", schemaName: "public"),
            defaults: suite.defaults
        )
        editor.refresh()

        for section in StructureSection.allCases {
            #expect(editor.adapter(for: section).model.store.layoutScope == .ephemeral, "\(section.rawValue)")
        }
    }

    // MARK: - Hidden columns

    @Test("A section starts with its lean default columns hidden")
    func defaultHiddenColumns() {
        let columns = StructureGridStateStore(section: .columns, defaults: suite.defaults)
        #expect(columns.columnLayout.hiddenColumns == StructureGridStateStore.defaultHiddenColumns(.columns))
        #expect(columns.columnLayout.hiddenColumns.contains(StructureColumnField.collation.displayName))
        #expect(!columns.columnLayout.hiddenColumns.contains(StructureColumnField.name.displayName))
        #expect(StructureGridStateStore(section: .indexes, defaults: suite.defaults).columnLayout.hiddenColumns.isEmpty)
    }

    @Test("Columns a person hides stay hidden for the next table, per section")
    func hiddenColumnsPersistPerSection() {
        let comment = StructureColumnField.comment.displayName
        let store = StructureGridStateStore(section: .columns, defaults: suite.defaults)
        store.columnLayout.hiddenColumns = [comment]

        #expect(StructureGridStateStore(section: .columns, defaults: suite.defaults).columnLayout.hiddenColumns == [comment])
        #expect(
            StructureGridStateStore(section: .foreignKeys, defaults: suite.defaults).columnLayout.hiddenColumns
                == StructureGridStateStore.defaultHiddenColumns(.foreignKeys)
        )
    }

    @Test("Showing every column is kept too, so the defaults do not come back")
    func showingEveryColumnPersists() {
        let store = StructureGridStateStore(section: .columns, defaults: suite.defaults)
        store.columnLayout.hiddenColumns = []

        #expect(StructureGridStateStore(section: .columns, defaults: suite.defaults).columnLayout.hiddenColumns.isEmpty)
    }

    @Test("A width change writes nothing to the defaults")
    func widthsAreNotPersisted() {
        let store = StructureGridStateStore(section: .indexes, defaults: suite.defaults)
        store.columnLayout.columnWidths["Name"] = 200

        #expect(suite.defaults.object(forKey: StructureGridStateStore.hiddenColumnsKey(.indexes)) == nil)
    }
}
