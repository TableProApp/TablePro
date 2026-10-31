//
//  StructureIndexTypeMenuTests.swift
//  TableProTests
//
//  The Indexes grid's Type cell and the inspector's Type field for an index whose type is outside the
//  known list, such as a PostgreSQL `bloom` index or a SQL Server `CLUSTERED` one.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureIndexTypeMenuTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func connection() -> DatabaseConnection {
        DatabaseConnection(name: "Test", host: "localhost", port: 5_432, database: "test", username: "u", type: .postgresql)
    }

    private func manager(indexTypes: [String]) -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "items",
            columns: [ColumnInfo(name: "a", dataType: "integer", isNullable: true, isPrimaryKey: false)],
            indexes: indexTypes.enumerated().map { offset, type in
                IndexInfo(name: "ix\(offset)", columns: ["a"], isUnique: false, isPrimary: false, type: type)
            },
            foreignKeys: [],
            primaryKey: []
        )
        return manager
    }

    private func makeEditor(_ manager: StructureChangeManager, creatingTable: Bool = false) -> StructureDefinitionEditor {
        let context: StructureEditingContext = creatingTable
            ? .newTable(connection: connection(), databaseName: "test", schemaName: nil)
            : .existingTable(
                connection: connection(),
                databaseName: "test",
                schemaName: nil,
                tableName: "items",
                objectKind: .table,
                isSessionBound: false
            )
        let editor = StructureDefinitionEditor(manager: manager, context: context, defaults: suite.defaults)
        editor.refresh()
        return editor
    }

    private func column(_ model: DataGridModel, dataIndex: Int) throws -> DataGridColumn {
        try #require(model.columns.columns.first { $0.dataIndex == dataIndex })
    }

    private func options(_ adapter: StructureSectionAdapter, sourceIndex: Int, dataIndex: Int) throws -> [String]? {
        adapter.gridMenuOptions(
            for: adapter.rowID(forEntity: adapter.manager.workingIndexes[sourceIndex].id),
            column: try column(adapter.model, dataIndex: dataIndex)
        )?.compactMap(\.sql)
    }

    private static let knownNames = EditableIndexDefinition.IndexType.knownTypes.map(\.rawValue)

    @Test("A bloom row offers BLOOM after the known types, and a b-tree row offers the known types alone")
    func rowOffersItsOwnType() throws {
        let editor = makeEditor(manager(indexTypes: ["bloom", "btree"]))
        let adapter = editor.adapter(for: .indexes)
        let typeColumn = StructureRowProvider.indexTypeColumn

        #expect(try options(adapter, sourceIndex: 0, dataIndex: typeColumn) == Self.knownNames + ["BLOOM"])
        #expect(try options(adapter, sourceIndex: 1, dataIndex: typeColumn) == Self.knownNames)
        #expect(try options(adapter, sourceIndex: 0, dataIndex: 3) == nil)
    }

    @Test("The inspector's Type menu for a CLUSTERED row holds the value it shows")
    func inspectorMenuHoldsTheRowType() throws {
        let editor = makeEditor(manager(indexTypes: ["CLUSTERED"]))
        let form = try #require(editor.inspectorForm(for: .indexes, id: editor.manager.workingIndexes[0].id))
        let typeField = form.fields[StructureRowProvider.indexTypeColumn]

        #expect(typeField.value == "CLUSTERED")
        #expect(typeField.kind == .menu(GridMenuOption.values(Self.knownNames + ["CLUSTERED"])))
    }

    @Test("The new-table grid offers a pasted index its own type the same way")
    func createTableOffersItsOwnType() throws {
        let editor = makeEditor(manager(indexTypes: ["hnsw"]), creatingTable: true)

        #expect(try options(editor.adapter(for: .indexes), sourceIndex: 0, dataIndex: StructureRowProvider.indexTypeColumn)
            == Self.knownNames + ["HNSW"])
    }

    @Test("A Type edit takes a known type and leaves the index alone for any other text")
    func typeEditAcceptsKnownTypesOnly() {
        var index = EditableIndexDefinition.from(IndexInfo(
            name: "ix", columns: ["a"], isUnique: false, isPrimary: false, type: "bloom"
        ))
        let typeColumn = StructureRowProvider.indexTypeColumn

        StructureEditingSupport.updateIndex(&index, at: typeColumn, with: "hnsw USING btree", keys: .testing(.postgresql))
        #expect(index.type.rawValue == "BLOOM")
        StructureEditingSupport.updateIndex(&index, at: typeColumn, with: "spgist", keys: .testing(.postgresql))
        #expect(index.type == .spgist)
    }
}
