//
//  StructureGridAdapterInspectorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureGridAdapterInspectorTests {
    private func connection(_ type: DatabaseType = .mysql) -> DatabaseConnection {
        DatabaseConnection(
            name: "Test",
            host: "localhost",
            port: type == .postgresql ? 5_432 : 3_306,
            database: "test",
            username: "root",
            type: type
        )
    }

    private func loadSchema(into manager: StructureChangeManager) {
        manager.loadSchema(
            tableName: "users",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "email", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
    }

    // The session owns the adapter in the app, and its search text is what filters the provider.
    private func makeSession(
        type: DatabaseType = .mysql,
        objectKind: TableInfo.TableType = .table,
        tab: StructureTab = .columns,
        searchText: String = ""
    ) -> StructureEditingSession {
        let session = StructureEditingSession(
            identity: "test.users",
            connection: connection(type),
            databaseName: "test",
            schemaName: nil,
            tableName: "users",
            objectKind: objectKind
        )
        loadSchema(into: session.changeManager)
        session.selectedTab = tab
        session.searchText = searchText
        session.gridAdapter.refresh()
        return session
    }

    private func fieldIndex(_ adapter: StructureGridAdapter, _ field: StructureColumnField) throws -> Int {
        try #require(adapter.provider.orderedColumnFields.firstIndex(of: field))
    }

    @Test("A row is read-only while a save holds the edits, and editable again once it lets go")
    func heldSaveMakesTheRowReadOnly() throws {
        let session = makeSession()
        let manager = session.changeManager
        let adapter = session.gridAdapter
        var email = try #require(manager.workingColumns.first { $0.name == "email" })
        email.comment = "Contact"
        manager.updateColumn(id: email.id, with: email)
        adapter.refresh()

        let snapshot = try #require(manager.holdForSave())
        #expect(adapter.inspectorRow(atDisplayRow: 1)?.isEditable == false)

        manager.releaseHold(snapshot, written: false)
        #expect(adapter.inspectorRow(atDisplayRow: 1)?.isEditable == true)
    }

    // A hold changes no row, so the inspector kept the fields it built before the save and dropped what was typed.
    @Test("A save hold and its release each rebuild the inspector")
    func heldSaveRebuildsTheInspector() throws {
        let fixture = CoordinatorFixture(connection: connection())
        let session = makeSession()
        let manager = session.changeManager
        let adapter = session.gridAdapter
        adapter.coordinator = fixture.coordinator
        var email = try #require(manager.workingColumns.first { $0.name == "email" })
        email.comment = "Contact"
        manager.updateColumn(id: email.id, with: email)
        adapter.refresh()
        let beforeHold = fixture.coordinator.inspectorRowSourceRevision

        let snapshot = try #require(manager.holdForSave())
        adapter.refresh()
        #expect(fixture.coordinator.inspectorRowSourceRevision == beforeHold + 1)

        manager.releaseHold(snapshot, written: false)
        adapter.refresh()
        #expect(fixture.coordinator.inspectorRowSourceRevision == beforeHold + 2)
    }

    @Test("The published row describes the structure grid, not the data grid")
    func publishedRowDescribesStructure() throws {
        let session = makeSession()
        let adapter = session.gridAdapter
        let row = try #require(adapter.inspectorRow(atDisplayRow: 1))

        #expect(row.fields.map(\.name) == adapter.provider.orderedColumnFields.map(\.displayName))
        #expect(row.fields.first?.value == "email")
    }

    @Test("An inspector edit lands on the column the display row points at under a search")
    func editResolvesFilteredDisplayRow() throws {
        let session = makeSession(searchText: "email")
        let adapter = session.gridAdapter
        #expect(adapter.model.rowCount == 1)

        adapter.commitInspectorField(
            displayRow: 0,
            fieldIndex: try fieldIndex(adapter, .name),
            value: "user_email"
        )

        #expect(session.changeManager.workingColumns[0].name == "id")
        #expect(session.changeManager.workingColumns[1].name == "user_email")
    }

    @Test("An inspector edit records a pending schema change")
    func editRecordsPendingChange() throws {
        let session = makeSession()
        let adapter = session.gridAdapter

        adapter.commitInspectorField(
            displayRow: 1,
            fieldIndex: try fieldIndex(adapter, .type),
            value: "TEXT"
        )

        #expect(session.changeManager.hasChanges)
        #expect(session.changeManager.workingColumns[1].dataType == "TEXT")
    }

    @Test("A flag field commits the value the dropdown offers")
    func flagEditCommitsBooleanValue() throws {
        let session = makeSession()
        let adapter = session.gridAdapter

        adapter.commitInspectorField(
            displayRow: 1,
            fieldIndex: try fieldIndex(adapter, .nullable),
            value: "NO"
        )

        #expect(session.changeManager.workingColumns[1].isNullable == false)
    }

    // A Foreign Keys inspector built before a reference list arrived holds only "Loading…" until it rebuilds.
    @Test("A reference list landing rebuilds the structure inspector")
    func referenceListArrivalRebuildsInspector() {
        let fixture = CoordinatorFixture(connection: connection())
        let session = makeSession(tab: .foreignKeys)
        session.gridAdapter.coordinator = fixture.coordinator
        let revision = fixture.coordinator.inspectorRowSourceRevision

        session.gridAdapter.referenceMenus.onListsChanged?()

        #expect(fixture.coordinator.inspectorRowSourceRevision == revision + 1)
    }

    @Test("Before its first refresh the adapter publishes nothing")
    func beforeRefreshPublishesNothing() {
        let manager = StructureChangeManager()
        loadSchema(into: manager)
        let adapter = StructureGridAdapter(
            structureChangeManager: manager,
            connection: connection(),
            tableName: "users",
            databaseName: "test",
            schemaName: nil,
            objectKind: .table,
            isSessionBound: false
        )

        #expect(adapter.inspectorRow(atDisplayRow: 0) == nil)
    }

    @Test("The new-table grid publishes its own rows and takes edits")
    func createTableAdapterPublishesRows() throws {
        let manager = StructureChangeManager()
        manager.addNewColumn()
        let adapter = CreateTableGridAdapter(structureChangeManager: manager, connection: connection())
        adapter.refresh()

        let row = try #require(adapter.inspectorRow(atDisplayRow: 0))
        #expect(row.isEditable)

        let nameIndex = try #require(adapter.provider.orderedColumnFields.firstIndex(of: .name))
        adapter.commitInspectorField(displayRow: 0, fieldIndex: nameIndex, value: "sku")
        #expect(manager.workingColumns[0].name == "sku")
    }

    // MARK: - A kind that locks fields

    // The grid locked a materialized view's Type, Nullable and Default while the inspector offered all three.
    private func makeMaterializedView(tab: StructureTab = .columns) -> StructureEditingSession {
        makeSession(type: .postgresql, objectKind: .materializedView, tab: tab)
    }

    @Test("A materialized view's inspector locks the fields its grid locks")
    func materializedViewInspectorLocksFields() throws {
        let adapter = makeMaterializedView().gridAdapter
        let row = try #require(adapter.inspectorRow(atDisplayRow: 1))

        #expect(row.isEditable)
        #expect(row.fields[try fieldIndex(adapter, .name)].isEditable)
        #expect(row.fields[try fieldIndex(adapter, .comment)].isEditable)
        #expect(!row.fields[try fieldIndex(adapter, .type)].isEditable)
        #expect(!row.fields[try fieldIndex(adapter, .nullable)].isEditable)
        #expect(!row.fields[try fieldIndex(adapter, .defaultValue)].isEditable)
    }

    @Test("The grid locks the same headings the inspector locks")
    func gridLocksTheSameHeadings() throws {
        let adapter = makeMaterializedView().gridAdapter
        let headings = adapter.provider.columns
        let locked = adapter.model.configuration.lockedColumns

        #expect(locked.contains(headings[try fieldIndex(adapter, .type)]))
        #expect(locked.contains(headings[try fieldIndex(adapter, .nullable)]))
        #expect(!locked.contains(headings[try fieldIndex(adapter, .name)]))
    }

    @Test("A locked field refuses the edit even when it arrives through the inspector")
    func lockedFieldRefusesTheCommit() throws {
        let session = makeMaterializedView()
        let adapter = session.gridAdapter

        adapter.commitInspectorField(displayRow: 1, fieldIndex: try fieldIndex(adapter, .type), value: "TEXT")
        adapter.commitInspectorField(displayRow: 1, fieldIndex: try fieldIndex(adapter, .defaultValue), value: "'x'")

        #expect(!session.changeManager.hasChanges)
        #expect(session.changeManager.workingColumns[1].dataType == "VARCHAR(255)")
        #expect(session.changeManager.workingColumns[1].defaultValue == nil)
    }

    @Test("An unlocked field on the same object still takes the edit")
    func unlockedFieldTakesTheCommit() throws {
        let session = makeMaterializedView()
        let adapter = session.gridAdapter

        adapter.commitInspectorField(displayRow: 1, fieldIndex: try fieldIndex(adapter, .name), value: "mail")

        #expect(session.changeManager.workingColumns[1].name == "mail")
    }

    @Test("A table locks nothing, so every field stays open")
    func tableLocksNothing() {
        let adapter = makeSession().gridAdapter
        #expect(adapter.lockedFieldIndices.isEmpty)
        #expect(adapter.model.configuration.lockedColumns.isEmpty)
    }

    @Test("The row commands offer Delete only where the object accepts the drop")
    func rowCommandsFollowTheGate() {
        let columns = makeMaterializedView(tab: .columns).gridAdapter
        #expect(!columns.canStageRemoveForSelectedTab)
        #expect(!columns.canStageAddForSelectedTab)
        #expect(columns.model.configuration.commands.isDisjoint(with: [.deleteRows, .addRow, .duplicateRows]))

        let indexes = makeMaterializedView(tab: .indexes).gridAdapter
        #expect(indexes.canStageRemoveForSelectedTab)
        #expect(indexes.canStageAddForSelectedTab)
        #expect(indexes.model.configuration.commands.isSuperset(of: [.deleteRows, .addRow, .duplicateRows]))
    }
}
