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

    private func structureAdapter(_ manager: StructureChangeManager) -> StructureGridAdapter {
        let adapter = StructureGridAdapter(
            structureChangeManager: manager,
            connection: connection(),
            tableName: "items",
            databaseName: "test",
            schemaName: nil,
            objectKind: .table,
            isSessionBound: false
        )
        adapter.store.switchSubTab(to: .indexes)
        adapter.refresh()
        return adapter
    }

    private func column(_ model: DataGridModel, dataIndex: Int) throws -> DataGridColumn {
        try #require(model.columns.columns.first { $0.dataIndex == dataIndex })
    }

    private func options(
        _ source: any DataGridDataSource,
        model: DataGridModel,
        sourceIndex: Int,
        dataIndex: Int
    ) throws -> [String]? {
        source.gridMenuOptions(
            for: StructureRowProvider.rowID(forSourceIndex: sourceIndex),
            column: try column(model, dataIndex: dataIndex)
        )?.compactMap(\.sql)
    }

    private static let knownNames = EditableIndexDefinition.IndexType.knownTypes.map(\.rawValue)

    @Test("A bloom row offers BLOOM after the known types, and a b-tree row offers the known types alone")
    func rowOffersItsOwnType() throws {
        let adapter = structureAdapter(manager(indexTypes: ["bloom", "btree"]))
        let typeColumn = StructureRowProvider.indexTypeColumn

        #expect(try options(adapter, model: adapter.model, sourceIndex: 0, dataIndex: typeColumn) == Self.knownNames + ["BLOOM"])
        #expect(try options(adapter, model: adapter.model, sourceIndex: 1, dataIndex: typeColumn) == Self.knownNames)
        #expect(try options(adapter, model: adapter.model, sourceIndex: 0, dataIndex: 3) == nil)
    }

    @Test("The inspector's Type picker for a CLUSTERED row holds the value it shows")
    func inspectorPickerHoldsTheRowType() throws {
        let adapter = structureAdapter(manager(indexTypes: ["CLUSTERED"]))
        let row = try #require(adapter.inspectorRow(atDisplayRow: 0))
        let typeField = row.fields[StructureRowProvider.indexTypeColumn]

        #expect(typeField.value == "CLUSTERED")
        #expect(typeField.editor == .enumPicker(values: Self.knownNames + ["CLUSTERED"]))
    }

    @Test("The new-table grid offers a pasted index its own type the same way")
    func createTableOffersItsOwnType() throws {
        let adapter = CreateTableGridAdapter(structureChangeManager: manager(indexTypes: ["hnsw"]), connection: connection())
        adapter.select(.indexes)

        #expect(try options(adapter, model: adapter.model, sourceIndex: 0, dataIndex: StructureRowProvider.indexTypeColumn)
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
