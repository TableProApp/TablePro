//
//  StructureGridDelegateInspectorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("Structure grid delegates as inspector row sources")
struct StructureGridDelegateInspectorTests {
    private func connection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Test",
            host: "localhost",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql
        )
    }

    private func loadedManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
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
        return manager
    }

    private func makeDelegate(
        manager: StructureChangeManager,
        filterText: String? = nil
    ) -> StructureGridDelegate {
        let delegate = StructureGridDelegate(
            structureChangeManager: manager,
            selectedTab: .columns,
            connection: connection(),
            tableName: "users",
            coordinator: nil
        )
        let provider = StructureRowProvider(
            changeManager: manager,
            tab: .columns,
            databaseType: .mysql,
            additionalFields: [.primaryKey],
            serverSupport: .unrestricted,
            filterText: filterText
        )
        delegate.currentProvider = provider
        delegate.orderedFields = provider.orderedColumnFields
        return delegate
    }

    private func fieldIndex(_ delegate: StructureGridDelegate, _ field: StructureColumnField) throws -> Int {
        try #require(delegate.orderedFields.firstIndex(of: field))
    }

    @Test("The published row describes the structure grid, not the data grid")
    func publishedRowDescribesStructure() throws {
        let delegate = makeDelegate(manager: loadedManager())
        let row = try #require(delegate.inspectorRow(atDisplayRow: 1))

        #expect(row.fields.map(\.name) == delegate.orderedFields.map(\.displayName))
        #expect(row.fields.first?.value == "email")
    }

    @Test("An inspector edit lands on the column the display row points at")
    func editResolvesFilteredDisplayRow() throws {
        let manager = loadedManager()
        let delegate = makeDelegate(manager: manager, filterText: "email")

        delegate.commitInspectorField(
            displayRow: 0,
            fieldIndex: try fieldIndex(delegate, .name),
            value: "user_email"
        )

        #expect(manager.workingColumns[0].name == "id")
        #expect(manager.workingColumns[1].name == "user_email")
    }

    @Test("An inspector edit records a pending schema change")
    func editRecordsPendingChange() throws {
        let manager = loadedManager()
        let delegate = makeDelegate(manager: manager)

        delegate.commitInspectorField(
            displayRow: 1,
            fieldIndex: try fieldIndex(delegate, .type),
            value: "TEXT"
        )

        #expect(manager.hasChanges)
        #expect(manager.workingColumns[1].dataType == "TEXT")
    }

    @Test("A flag field commits the value the dropdown offers")
    func flagEditCommitsBooleanValue() throws {
        let manager = loadedManager()
        let delegate = makeDelegate(manager: manager)

        delegate.commitInspectorField(
            displayRow: 1,
            fieldIndex: try fieldIndex(delegate, .nullable),
            value: "NO"
        )

        #expect(manager.workingColumns[1].isNullable == false)
    }

    /// The Foreign Keys inspector offers the same reference lists the grid does. One built before a
    /// list arrived holds only `Loading…`, and nothing rebuilt it, because only Create Table moved
    /// the inspector's revision when a list landed.
    @Test("A reference list landing rebuilds the structure inspector")
    func referenceListArrivalRebuildsInspector() {
        let coordinator = MainContentCoordinator(
            connection: connection(),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let delegate = StructureGridDelegate(
            structureChangeManager: loadedManager(),
            selectedTab: .foreignKeys,
            connection: connection(),
            tableName: "users",
            coordinator: coordinator
        )
        let revision = coordinator.inspectorRowSourceRevision

        delegate.referenceMenus.onListsChanged?()

        #expect(coordinator.inspectorRowSourceRevision == revision + 1)
    }

    @Test("Without a provider the delegate publishes nothing")
    func withoutProviderPublishesNothing() {
        let delegate = StructureGridDelegate(
            structureChangeManager: loadedManager(),
            selectedTab: .columns,
            connection: connection(),
            tableName: "users",
            coordinator: nil
        )

        #expect(delegate.inspectorRow(atDisplayRow: 0) == nil)
    }

    @Test("The new-table grid publishes its own rows and takes edits")
    func createTableDelegatePublishesRows() throws {
        let manager = StructureChangeManager()
        manager.addNewColumn()
        let delegate = CreateTableGridDelegate(
            structureChangeManager: manager,
            structureTab: .columns,
            connection: connection()
        )
        let provider = StructureRowProvider(
            changeManager: manager,
            tab: .columns,
            databaseType: .mysql,
            additionalFields: [.primaryKey],
            serverSupport: .unrestricted
        )
        delegate.orderedFields = provider.orderedColumnFields

        let row = try #require(delegate.inspectorRow(atDisplayRow: 0))
        #expect(row.isEditable)

        let nameIndex = try #require(delegate.orderedFields.firstIndex(of: .name))
        delegate.commitInspectorField(displayRow: 0, fieldIndex: nameIndex, value: "sku")
        #expect(manager.workingColumns[0].name == "sku")
    }

    // MARK: - A kind that locks fields

    /// The grid locked a materialized view's Type, Nullable and Default, while the inspector beside
    /// it offered all three and staged an `ALTER COLUMN` PostgreSQL always refuses on a matview.
    private func makeMaterializedViewDelegate(
        manager: StructureChangeManager,
        tab: StructureTab = .columns
    ) -> StructureGridDelegate {
        let connection = DatabaseConnection(
            name: "Test", host: "localhost", port: 5_432, database: "shop", username: "postgres", type: .postgresql
        )
        let delegate = StructureGridDelegate(
            structureChangeManager: manager,
            selectedTab: tab,
            connection: connection,
            tableName: "daily_totals",
            objectKind: .materializedView,
            coordinator: nil
        )
        let provider = StructureRowProvider(
            changeManager: manager,
            tab: tab,
            databaseType: .postgresql,
            serverSupport: .unrestricted
        )
        delegate.currentProvider = provider
        delegate.orderedFields = provider.orderedColumnFields
        return delegate
    }

    @Test("A materialized view's inspector locks the fields its grid locks")
    func materializedViewInspectorLocksFields() throws {
        let delegate = makeMaterializedViewDelegate(manager: loadedManager())
        let row = try #require(delegate.inspectorRow(atDisplayRow: 1))

        #expect(row.isEditable)
        #expect(row.fields[try fieldIndex(delegate, .name)].isEditable)
        #expect(row.fields[try fieldIndex(delegate, .comment)].isEditable)
        #expect(!row.fields[try fieldIndex(delegate, .type)].isEditable)
        #expect(!row.fields[try fieldIndex(delegate, .nullable)].isEditable)
        #expect(!row.fields[try fieldIndex(delegate, .defaultValue)].isEditable)
    }

    @Test("A locked field refuses the edit even when it arrives through the inspector")
    func lockedFieldRefusesTheCommit() throws {
        let manager = loadedManager()
        let delegate = makeMaterializedViewDelegate(manager: manager)

        delegate.commitInspectorField(displayRow: 1, fieldIndex: try fieldIndex(delegate, .type), value: "TEXT")
        delegate.commitInspectorField(displayRow: 1, fieldIndex: try fieldIndex(delegate, .defaultValue), value: "'x'")

        #expect(!manager.hasChanges)
        #expect(manager.workingColumns[1].dataType == "VARCHAR(255)")
        #expect(manager.workingColumns[1].defaultValue == nil)
    }

    @Test("An unlocked field on the same object still takes the edit")
    func unlockedFieldTakesTheCommit() throws {
        let manager = loadedManager()
        let delegate = makeMaterializedViewDelegate(manager: manager)

        delegate.commitInspectorField(displayRow: 1, fieldIndex: try fieldIndex(delegate, .name), value: "mail")

        #expect(manager.workingColumns[1].name == "mail")
    }

    @Test("A table locks nothing, so every field stays open")
    func tableLocksNothing() {
        #expect(makeDelegate(manager: loadedManager()).lockedFieldIndices.isEmpty)
    }

    @Test("The row menu offers Delete only where the object accepts the drop")
    func rowMenuFollowsTheGate() {
        let columns = makeMaterializedViewDelegate(manager: loadedManager(), tab: .columns)
        #expect(!columns.canStageRemoveForSelectedTab)
        #expect(!columns.canStageAddForSelectedTab)

        let indexes = makeMaterializedViewDelegate(manager: loadedManager(), tab: .indexes)
        #expect(indexes.canStageRemoveForSelectedTab)
        #expect(indexes.canStageAddForSelectedTab)
    }
}
