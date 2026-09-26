//
//  StructureChangeManagerClusteredIndexTests.swift
//  TableProTests
//
//  A copied SQL Server clustered index added to a table that already keeps its rows in one.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureChangeManagerClusteredIndexTests {
    private typealias IndexType = EditableIndexDefinition.IndexType

    private static func manager(indexes: [IndexInfo]) -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true),
                ColumnInfo(name: "placed_at", dataType: "int", isNullable: true, isPrimaryKey: false)
            ],
            indexes: indexes,
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    private static let clusteredPrimaryKey = IndexInfo(
        name: "PK_orders", columns: ["id"], isUnique: true, isPrimary: true, type: "CLUSTERED"
    )

    private static func copied(_ name: String, type: IndexType) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: ["placed_at"], type: type, isUnique: false, isPrimary: false,
            comment: nil
        )
    }

    /// Duplicate stages the primary key's own row with `isPrimary` cleared, and a SQL Server primary
    /// key is clustered by default.
    @Test("A duplicated clustered primary key is added NONCLUSTERED and written that way")
    func duplicateOfClusteredKeyIsNonclustered() throws {
        let manager = Self.manager(indexes: [Self.clusteredPrimaryKey])
        var duplicate = try #require(manager.workingIndexes.first).withNewIdentity()
        duplicate.isPrimary = false
        duplicate.name = "ux_orders_id"

        manager.addIndex(duplicate)

        let added = try #require(manager.workingIndexes.last)
        #expect(added.type == .nonclustered)
        #expect(
            MSSQLTableDefinitionSQL.indexDefinition(added.toPlugin(), qualifiedTable: "[dbo].[orders]")
                == "CREATE UNIQUE NONCLUSTERED INDEX [ux_orders_id] ON [dbo].[orders] ([id])"
        )
    }

    @Test("A clustered index pasted into a heap stays CLUSTERED, and a second one beside it does not")
    func heapTakesOneClusteredIndex() throws {
        let manager = Self.manager(indexes: [])

        manager.addIndex(Self.copied("ix_first", type: .clustered))
        manager.addIndex(Self.copied("ix_second", type: .clustered))

        #expect(manager.workingIndexes.map(\.type) == [.clustered, .nonclustered])
    }

    @Test("A clustered columnstore index already on the table counts as the clustered one")
    func clusteredColumnstoreCounts() throws {
        let manager = Self.manager(indexes: [
            IndexInfo(name: "cci_orders", columns: ["id"], isUnique: false, isPrimary: false, type: "CLUSTERED COLUMNSTORE")
        ])

        manager.addIndex(Self.copied("ix_placed", type: .clustered))

        #expect(manager.workingIndexes.last?.type == .nonclustered)
    }

    /// The save drops every index before it adds one, so the replacement is the table's clustered index.
    @Test("A clustered index added in place of one being deleted stays CLUSTERED")
    func replacementForDeletedClusteredIndexStaysClustered() throws {
        let manager = Self.manager(indexes: [Self.clusteredPrimaryKey])
        let primaryKey = try #require(manager.workingIndexes.first)
        manager.deleteIndex(id: primaryKey.id)

        manager.addIndex(Self.copied("ix_placed", type: .clustered))

        #expect(manager.workingIndexes.last?.type == .clustered)
    }

    private static let clusteredIndex = IndexInfo(
        name: "cx_orders_placed", columns: ["placed_at"], isUnique: false, isPrimary: false, type: "CLUSTERED"
    )

    /// Duplicate, edit the copy, then delete the original is how the Structure tab replaces an index.
    /// Left `NONCLUSTERED`, the copy is created after the original is dropped, and the table ends the
    /// save with no clustered index.
    @Test("A duplicated clustered index takes the clustered place once the original is deleted")
    func duplicateTakesThePlaceOfTheDeletedOriginal() throws {
        let manager = Self.manager(indexes: [Self.clusteredIndex])
        let original = try #require(manager.workingIndexes.first)
        manager.addIndex(original.withNewIdentity())
        var copy = try #require(manager.workingIndexes.last)
        #expect(copy.type == .nonclustered)
        copy.columns = ["placed_at", "id"]
        manager.updateIndex(id: copy.id, with: copy)

        manager.deleteIndex(id: original.id)

        let replacement = try #require(manager.workingIndexes.last)
        #expect(replacement.type == .clustered)
        #expect(manager.canCommit)
        #expect(manager.getChangesArray() == [.addIndex(replacement), .deleteIndex(original)])
        #expect(
            MSSQLTableDefinitionSQL.indexDefinition(replacement.toPlugin(), qualifiedTable: "[dbo].[orders]")
                == "CREATE CLUSTERED INDEX [cx_orders_placed] ON [dbo].[orders] ([placed_at], [id])"
        )
    }

    @Test("Bringing the original back gives it the clustered place again")
    func undoingTheDeletionGivesThePlaceBack() throws {
        let manager = Self.manager(indexes: [Self.clusteredIndex])
        let original = try #require(manager.workingIndexes.first)
        manager.addIndex(original.withNewIdentity())
        manager.deleteIndex(id: original.id)
        #expect(manager.workingIndexes.last?.type == .clustered)

        manager.undo()

        let copy = try #require(manager.workingIndexes.last)
        #expect(copy.type == .nonclustered)
        #expect(manager.getChangesArray() == [.addIndex(copy)])
    }

    @Test("When the first of two clustered copies is removed, the second takes the place")
    func removingTheFirstCopyHandsThePlaceOn() throws {
        let manager = Self.manager(indexes: [])
        let first = Self.copied("ix_first", type: .clustered)
        manager.addIndex(first)
        manager.addIndex(Self.copied("ix_second", type: .clustered))

        manager.deleteIndex(id: first.id)

        #expect(manager.workingIndexes.map(\.name) == ["ix_second"])
        #expect(manager.workingIndexes.map(\.type) == [.clustered])
    }

    @Test("A copy whose type was changed keeps the type it was given")
    func aTypeChosenForTheCopyIsKept() throws {
        let manager = Self.manager(indexes: [Self.clusteredIndex])
        let original = try #require(manager.workingIndexes.first)
        manager.addIndex(original.withNewIdentity())
        var copy = try #require(manager.workingIndexes.last)
        copy.type = .hash
        manager.updateIndex(id: copy.id, with: copy)

        manager.deleteIndex(id: original.id)

        #expect(manager.workingIndexes.last?.type == .hash)
    }

    @Test("A clustered copy set to NONCLUSTERED stays that way while the clustered place is free")
    func nonclusteredChosenForTheCopyIsKept() throws {
        let manager = Self.manager(indexes: [])
        manager.addIndex(Self.copied("ix_copy", type: .clustered))
        var copy = try #require(manager.workingIndexes.last)
        #expect(copy.type == .clustered)
        copy.type = .nonclustered
        manager.updateIndex(id: copy.id, with: copy)

        manager.addIndex(Self.copied("ix_other", type: .hash))

        #expect(manager.workingIndexes.first?.type == .nonclustered)
    }

    @Test("Every other type is added as it was copied")
    func otherTypesAreUntouched() throws {
        let manager = Self.manager(indexes: [Self.clusteredPrimaryKey])

        manager.addIndex(Self.copied("ix_nonclustered", type: .nonclustered))
        manager.addIndex(Self.copied("ix_hnsw", type: IndexType(rawValue: "hnsw")))
        manager.addIndex(Self.copied("ix_columnstore", type: IndexType(rawValue: "CLUSTERED COLUMNSTORE")))

        #expect(manager.workingIndexes.dropFirst().map(\.type.rawValue) == [
            "NONCLUSTERED", "HNSW", "CLUSTERED COLUMNSTORE"
        ])
    }
}
