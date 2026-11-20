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

    @Test("Each of two twin schemas resolves its own children, and expands on its own")
    func twinSchemaChildrenStayApart() {
        let coordinator = DatabaseTreeOutlineCoordinator()
        let composed = DatabaseTreeNode(
            id: DatabaseTreeNode.schemaId(database: "shop", schema: TwinNames.composed),
            kind: .schema(database: "shop", schema: TwinNames.composed)
        )
        let decomposed = DatabaseTreeNode(
            id: DatabaseTreeNode.schemaId(database: "shop", schema: TwinNames.decomposed),
            kind: .schema(database: "shop", schema: TwinNames.decomposed)
        )
        let first = DatabaseTreeNode(id: "first", kind: .schema(database: "shop", schema: "first"))
        let second = DatabaseTreeNode(id: "second", kind: .schema(database: "shop", schema: "second"))
        coordinator.childrenCache = [CatalogName(composed.id): [first], CatalogName(decomposed.id): [second]]

        #expect(coordinator.resolvedChildren(of: composed).first === first)
        #expect(coordinator.resolvedChildren(of: decomposed).first === second)
        #expect(Set([
            DatabaseSchemaKey(database: "shop", schema: TwinNames.composed),
            DatabaseSchemaKey(database: "shop", schema: TwinNames.decomposed)
        ]).count == 2)
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
