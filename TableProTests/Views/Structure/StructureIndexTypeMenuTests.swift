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

    private func structureDelegate(_ manager: StructureChangeManager) -> StructureGridDelegate {
        let delegate = StructureGridDelegate(
            structureChangeManager: manager,
            selectedTab: .indexes,
            connection: connection(),
            tableName: "items",
            coordinator: nil
        )
        delegate.currentProvider = StructureRowProvider(
            changeManager: manager,
            tab: .indexes,
            databaseType: .postgresql,
            serverSupport: .unrestricted
        )
        return delegate
    }

    private static let knownNames = EditableIndexDefinition.IndexType.knownTypes.map(\.rawValue)

    @Test("A bloom row offers BLOOM after the known types, and a b-tree row offers the known types alone")
    func rowOffersItsOwnType() {
        let delegate = structureDelegate(manager(indexTypes: ["bloom", "btree"]))
        let typeColumn = StructureRowProvider.indexTypeColumn

        #expect(delegate.dataGridMenuOptions(forRow: 0, columnIndex: typeColumn)?.compactMap(\.sql)
            == Self.knownNames + ["BLOOM"])
        #expect(delegate.dataGridMenuOptions(forRow: 1, columnIndex: typeColumn)?.compactMap(\.sql)
            == Self.knownNames)
        #expect(delegate.dataGridMenuOptions(forRow: 0, columnIndex: 3) == nil)
    }

    @Test("The inspector's Type picker for a CLUSTERED row holds the value it shows")
    func inspectorPickerHoldsTheRowType() throws {
        let delegate = structureDelegate(manager(indexTypes: ["CLUSTERED"]))
        let row = try #require(delegate.inspectorRow(atDisplayRow: 0))
        let typeField = row.fields[StructureRowProvider.indexTypeColumn]

        #expect(typeField.value == "CLUSTERED")
        #expect(typeField.editor == .enumPicker(values: Self.knownNames + ["CLUSTERED"]))
    }

    @Test("The new-table grid offers a pasted index its own type the same way")
    func createTableOffersItsOwnType() {
        let manager = manager(indexTypes: ["hnsw"])
        let delegate = CreateTableGridDelegate(structureChangeManager: manager, structureTab: .indexes, connection: connection())

        #expect(delegate.dataGridMenuOptions(forRow: 0, columnIndex: StructureRowProvider.indexTypeColumn)?
            .compactMap(\.sql) == Self.knownNames + ["HNSW"])
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
