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
            additionalFields: [.primaryKey]
        )
        delegate.orderedFields = provider.orderedColumnFields

        let row = try #require(delegate.inspectorRow(atDisplayRow: 0))
        #expect(row.isEditable)

        let nameIndex = try #require(delegate.orderedFields.firstIndex(of: .name))
        delegate.commitInspectorField(displayRow: 0, fieldIndex: nameIndex, value: "sku")
        #expect(manager.workingColumns[0].name == "sku")
    }
}
