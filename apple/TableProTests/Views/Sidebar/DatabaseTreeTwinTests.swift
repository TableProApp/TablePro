import Foundation
@testable import TablePro
import Testing

@MainActor
struct DatabaseTreeTwinTests {
    @Test("The sidebar lists both of two tables whose names differ only in Unicode form")
    func bothTwinTablesAreListed() {
        let tables = [TwinNames.composed, TwinNames.decomposed].map { TestFixtures.makeTableInfo(name: $0, schema: "public") }

        let listed = DatabaseTreeFilter.filteredTables(tables, searchText: "")

        #expect(listed.count == 2)
        #expect(listed.map { CatalogName($0.name) } == [CatalogName(TwinNames.composed), CatalogName(TwinNames.decomposed)])
    }

    @Test("The tree lists both of two twin schemas and groups their tables apart")
    func bothTwinSchemasAreListed() {
        let schemas = DatabaseTreeFilter.visibleSchemas(
            [TwinNames.composed, TwinNames.decomposed],
            systemSchemas: [],
            activeSchema: nil,
            showsSystem: false,
            searchText: "",
            contentMatches: { _ in true }
        )
        let groups = DatabaseTreeFilter.SchemaListingGroups(tables: [
            TestFixtures.makeTableInfo(name: "a", schema: TwinNames.composed),
            TestFixtures.makeTableInfo(name: "b", schema: TwinNames.decomposed)
        ])

        #expect(schemas.count == 2)
        #expect(groups.rowsBySchema[CatalogName(TwinNames.composed)]?.map(\.name) == ["a"])
        #expect(groups.rowsBySchema[CatalogName(TwinNames.decomposed)]?.map(\.name) == ["b"])
    }

    @Test("Each twin table keeps a row object of its own")
    func nodeCacheKeepsTwinRowsApart() {
        var cache: DatabaseTreeNodeCache = [:]
        let composedId = DatabaseTreeNode.schemaId(database: "shop", schema: TwinNames.composed)
        let decomposedId = DatabaseTreeNode.schemaId(database: "shop", schema: TwinNames.decomposed)
        let composed = DatabaseTreeNode(id: composedId, kind: .schema(database: "shop", schema: TwinNames.composed))
        let decomposed = DatabaseTreeNode(id: decomposedId, kind: .schema(database: "shop", schema: TwinNames.decomposed))

        cache[composedId] = composed
        cache[decomposedId] = decomposed

        #expect(cache.count == 2)
        #expect(cache[composedId] === composed)
        #expect(cache[decomposedId] === decomposed)
    }
}
