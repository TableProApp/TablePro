import Foundation
@testable import TablePro
import Testing

@MainActor
struct TwinCatalogKeyTests {
    private static let connectionId = UUID()

    private static func scope(schema: String) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "shop", schema: schema)
    }

    @Test("A schema's foreign keys are found for the twin that declares them, never for the other")
    func foreignKeyStoreKeepsTwinsApart() {
        let store = SchemaForeignKeyStore()
        let key = TestFixtures.makeForeignKeyInfo(column: "parent_id", referencedTable: "parent")
        store.store([CatalogName(TwinNames.decomposed): [key]], for: Self.scope(schema: "public"))

        #expect(store.foreignKeysByColumn(for: Self.scope(schema: "public"), table: TwinNames.decomposed)?.keys.sorted() == ["parent_id"])
        #expect(store.foreignKeysByColumn(for: Self.scope(schema: "public"), table: TwinNames.composed) == [:])
        #expect(store.foreignKeysByColumn(for: Self.scope(schema: TwinNames.composed), table: TwinNames.decomposed) == nil)
    }

    @Test("Two schemas whose names differ only in Unicode form keep their own sidebar lists")
    func treeKeysKeepTwinSchemasApart() {
        let composed = DatabaseTreeMetadataService.ObjectsKey(connectionId: Self.connectionId, database: "shop", schema: TwinNames.composed)
        let decomposed = DatabaseTreeMetadataService.ObjectsKey(connectionId: Self.connectionId, database: "shop", schema: TwinNames.decomposed)

        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        #expect(DatabaseTreeMetadataService.DatabaseKey(connectionId: Self.connectionId, database: TwinNames.composed)
            != DatabaseTreeMetadataService.DatabaseKey(connectionId: Self.connectionId, database: TwinNames.decomposed))
    }

    @Test("A key into a twin schema points outside this one")
    func foreignKeyTargetComparesSchemasByBytes() {
        #expect(!ForeignKeyTargetScope.pointsWithin(
            Self.scope(schema: TwinNames.composed),
            referencedDatabase: nil,
            referencedSchema: TwinNames.decomposed,
            slot: .schema
        ))
        #expect(ForeignKeyTargetScope.pointsWithin(
            Self.scope(schema: TwinNames.composed),
            referencedDatabase: nil,
            referencedSchema: TwinNames.composed,
            slot: .schema
        ))
    }

    @Test("A table dropped first frees its own index names, not its twin's")
    func droppedTwinKeepsTheOthersIndexNames() {
        let kept = ObjectCopyIndexNames.kept(
            [CatalogName(TwinNames.composed): ["composed_idx"], CatalogName(TwinNames.decomposed): ["decomposed_idx"]],
            droppingFirst: [CatalogName(TwinNames.decomposed)]
        )

        #expect(kept == NewTableNaming.comparisonKeys(for: ["composed_idx"]))
    }
}
