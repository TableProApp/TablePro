//
//  StructureSectionAdapterTests.swift
//  TableProTests
//
//  Add and Delete per section, the contract the +/- beneath each table, Cmd+Shift+N and the row menus share.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureSectionAdapterTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeEditor(
        type: DatabaseType = .mysql,
        objectKind: TableInfo.TableType = .table,
        manager: StructureChangeManager = StructureChangeManager()
    ) -> StructureDefinitionEditor {
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .existingTable(
                connection: TestFixtures.makeConnection(type: type),
                databaseName: "db",
                schemaName: nil,
                tableName: "t",
                objectKind: objectKind,
                isSessionBound: false
            ),
            defaults: suite.defaults
        )
        editor.refresh()
        return editor
    }

    private func row(_ sourceIndex: Int, in adapter: StructureSectionAdapter) -> RowID {
        adapter.rowID(forEntity: StructureGridEdits.entityIDs(in: adapter.section, manager: adapter.manager)[sourceIndex])
    }

    private func columns(named names: [String]) -> StructureChangeManager {
        let manager = StructureChangeManager()
        for name in names {
            var column = EditableColumnDefinition.placeholder()
            column.name = name
            column.dataType = "TEXT"
            manager.addColumn(column)
        }
        return manager
    }

    @Test("Columns: Add Row appends a placeholder column")
    func columnsAddsColumn() {
        let editor = makeEditor()
        let before = editor.manager.workingColumns.count
        editor.adapter(for: .columns).gridAddRow()
        #expect(editor.manager.workingColumns.count == before + 1)
    }

    @Test("Indexes: Add Row appends a placeholder index")
    func indexesAddsIndex() {
        let editor = makeEditor()
        let before = editor.manager.workingIndexes.count
        editor.adapter(for: .indexes).gridAddRow()
        #expect(editor.manager.workingIndexes.count == before + 1)
    }

    @Test("Foreign keys: Add Row appends a placeholder foreign key")
    func foreignKeysAddsForeignKey() {
        let editor = makeEditor()
        let before = editor.manager.workingForeignKeys.count
        editor.adapter(for: .foreignKeys).gridAddRow()
        #expect(editor.manager.workingForeignKeys.count == before + 1)
    }

    @Test("Each section adds only its own kind of definition", arguments: StructureSection.allCases)
    func addStaysInItsSection(section: StructureSection) {
        let editor = makeEditor(type: .postgresql)
        editor.adapter(for: section).gridAddRow()

        for other in StructureSection.allCases {
            let count = StructureGridEdits.rowCount(on: other, manager: editor.manager)
            #expect(count == (other == section ? 1 : 0), "\(other.rawValue)")
        }
    }

    // SQLite's curated snapshot overrides neither supportsAddIndex nor supportsDropIndex, so both default to true.
    @Test("Indexes on SQLite: Add Row appends an index")
    func sqliteIndexesAddsAnIndex() {
        let editor = makeEditor(type: .sqlite)
        let before = editor.manager.workingIndexes.count
        editor.adapter(for: .indexes).gridAddRow()
        #expect(editor.manager.workingIndexes.count == before + 1)
    }

    @Test("Columns: Delete removes the column the row names")
    func columnsDeleteRemovesColumn() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .columns)
        adapter.gridAddRow()
        let after = editor.manager.workingColumns.count
        #expect(after > 0)
        adapter.gridDeleteRows([row(after - 1, in: adapter)])
        #expect(editor.manager.workingColumns.count == after - 1)
    }

    @Test("Indexes: Delete removes the index the row names")
    func indexesDeleteRemovesIndex() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .indexes)
        adapter.gridAddRow()
        let after = editor.manager.workingIndexes.count
        #expect(after > 0)
        adapter.gridDeleteRows([row(after - 1, in: adapter)])
        #expect(editor.manager.workingIndexes.count == after - 1)
    }

    @Test("Foreign keys: Delete removes the foreign key the row names")
    func foreignKeysDeleteRemovesForeignKey() {
        let editor = makeEditor()
        let adapter = editor.adapter(for: .foreignKeys)
        adapter.gridAddRow()
        let after = editor.manager.workingForeignKeys.count
        #expect(after > 0)
        adapter.gridDeleteRows([row(after - 1, in: adapter)])
        #expect(editor.manager.workingForeignKeys.count == after - 1)
    }

    @Test("Indexes on SQLite: Delete removes an index")
    func sqliteIndexesDeletesAnIndex() {
        let manager = StructureChangeManager()
        manager.addIndex(.placeholder())
        let editor = makeEditor(type: .sqlite, manager: manager)
        let adapter = editor.adapter(for: .indexes)
        let before = manager.workingIndexes.count

        adapter.gridDeleteRows([row(before - 1, in: adapter)])

        #expect(manager.workingIndexes.count == before - 1)
    }

    @Test("Deleting the last row selects the row above it")
    func deletingTheLastRowSelectsTheOneAbove() {
        let manager = StructureChangeManager()
        for _ in 0..<3 {
            manager.addColumn(.placeholder())
        }
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .columns)
        let above = row(1, in: adapter)
        adapter.model.selectRows([row(2, in: adapter)])

        adapter.gridDeleteRows([row(2, in: adapter)])

        #expect(manager.workingColumns.count == 2)
        #expect(adapter.model.selectedRowIDs == [above])
    }

    // MARK: - Row identity

    // A RowID was the definition's index, so removing one above moved the selection onto its neighbour.
    @Test("The selection stays on its definition across a refresh after a definition above it is removed")
    func selectionSurvivesRemovalAbove() {
        let manager = columns(named: ["a", "b", "c"])
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .columns)
        let c = manager.workingColumns[2].id
        let rowID = adapter.rowID(forEntity: c)
        adapter.select(entity: c)
        #expect(adapter.sourceIndex(of: rowID) == 2)

        manager.deleteColumn(id: manager.workingColumns[0].id)
        editor.refresh()

        #expect(manager.workingColumns.map(\.name) == ["b", "c"])
        #expect(adapter.rowID(forEntity: c) == rowID)
        #expect(adapter.entityID(of: rowID) == c)
        #expect(adapter.sourceIndex(of: rowID) == 1)
        #expect(adapter.model.selectedRowIDs == [rowID])
        #expect(adapter.selectedEntityIDs == [c])
        #expect(editor.inspectorTarget == .entity(.columns, c))
    }

    @Test("A sort reorders the rows without renaming them")
    func rowIDSurvivesSort() {
        let manager = columns(named: ["a", "b", "c"])
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .columns)
        let a = manager.workingColumns[0].id

        adapter.sortDidChange(SortState(columns: [SortColumn(columnIndex: 0, direction: .descending)], source: .user))

        #expect(adapter.model.rowID(at: 2) == adapter.rowID(forEntity: a))
        #expect(adapter.sourceIndex(of: adapter.rowID(forEntity: a)) == 0)
    }

    // MARK: - Several rows

    @Test("Duplicating several rows is one undo step")
    func duplicateIsOneUndoStep() {
        let manager = columns(named: ["a", "b", "c"])
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .columns)

        adapter.gridDuplicateRows([row(0, in: adapter), row(2, in: adapter)])
        #expect(manager.workingColumns.map(\.name) == ["a", "b", "c", "a", "c"])

        manager.undo()

        #expect(manager.workingColumns.map(\.name) == ["a", "b", "c"])
    }

    @Test("Deleting several rows is one undo step")
    func deleteIsOneUndoStep() {
        let manager = columns(named: ["a", "b", "c"])
        let editor = makeEditor(manager: manager)
        let adapter = editor.adapter(for: .columns)

        adapter.gridDeleteRows([row(0, in: adapter), row(2, in: adapter)])
        #expect(manager.workingColumns.map(\.name) == ["b"])

        manager.undo()

        #expect(manager.workingColumns.map(\.name) == ["a", "b", "c"])
    }

    // MARK: - Per object kind

    // Cmd+Shift+N, the row menus and the +/- all reach the adapter, so it refuses for itself (#2726).
    @Test("A PostgreSQL view refuses an added column, whatever reaches the adapter")
    func viewRefusesAnAddedColumn() {
        let editor = makeEditor(type: .postgresql, objectKind: .view)
        let adapter = editor.adapter(for: .columns)
        adapter.gridAddRow()
        #expect(editor.manager.workingColumns.isEmpty)
        #expect(!adapter.model.configuration.commands.contains(.addRow))
    }

    @Test("A PostgreSQL view refuses an added index and a materialized view accepts one")
    func indexesFollowTheObjectKind() {
        let view = makeEditor(type: .postgresql, objectKind: .view)
        view.adapter(for: .indexes).gridAddRow()
        #expect(view.manager.workingIndexes.isEmpty)

        let matview = makeEditor(type: .postgresql, objectKind: .materializedView)
        matview.adapter(for: .indexes).gridAddRow()
        #expect(matview.manager.workingIndexes.count == 1)
    }

    @Test("A PostgreSQL materialized view refuses a foreign key")
    func materializedViewRefusesAForeignKey() {
        let editor = makeEditor(type: .postgresql, objectKind: .materializedView)
        editor.adapter(for: .foreignKeys).gridAddRow()
        #expect(editor.manager.workingForeignKeys.isEmpty)
    }

    @Test("A view refuses to drop a column its own grid is showing")
    func viewRefusesADroppedColumn() {
        let manager = StructureChangeManager()
        manager.addColumn(.placeholder())
        #expect(manager.workingColumns.count == 1)
        let editor = makeEditor(type: .postgresql, objectKind: .view, manager: manager)
        let view = editor.adapter(for: .columns)

        view.gridDeleteRows([row(0, in: view)])

        #expect(manager.workingColumns.count == 1)
        #expect(!view.model.configuration.commands.contains(.deleteRows))
    }

    @Test("A system table refuses every add", arguments: StructureSection.allCases)
    func systemTableRefusesEveryAdd(section: StructureSection) {
        let editor = makeEditor(type: .postgresql, objectKind: .systemTable)
        editor.adapter(for: section).gridAddRow()
        #expect(editor.manager.workingColumns.isEmpty)
        #expect(editor.manager.workingIndexes.isEmpty)
        #expect(editor.manager.workingForeignKeys.isEmpty)
        #expect(editor.manager.workingCheckConstraints.isEmpty)
    }
}
