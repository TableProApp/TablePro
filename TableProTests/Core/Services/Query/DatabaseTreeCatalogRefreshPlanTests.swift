//
//  DatabaseTreeCatalogRefreshPlanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Database tree catalog refresh plan")
struct DatabaseTreeCatalogRefreshPlanTests {
    private typealias ObjectsKey = DatabaseTreeMetadataService.ObjectsKey
    private typealias DatabaseKey = DatabaseTreeMetadataService.DatabaseKey

    private let connectionId = UUID()

    private func plan(
        _ change: CatalogChange,
        hasDatabaseList: Bool = true,
        keys: [ObjectsKey],
        schemaLists: [DatabaseKey] = []
    ) -> CatalogTreeRefreshPlan {
        DatabaseTreeMetadataService.catalogRefreshPlan(
            for: change,
            hasDatabaseList: hasDatabaseList,
            schemaListKeys: schemaLists,
            tableKeys: keys,
            routineKeys: keys,
            triggerKeys: keys,
            typeKeys: keys
        )
    }

    @Test("routines, triggers and types are refreshed, not only tables")
    func everyObjectKindIsReached() {
        let shop = ObjectsKey(connectionId: connectionId, database: "shop", schema: nil)

        let result = plan(CatalogChange(connectionId: connectionId, kinds: .objects), keys: [shop])

        #expect(result.tables == [shop])
        #expect(result.routines == [shop])
        #expect(result.triggers == [shop])
        #expect(result.types == [shop])
    }

    @Test("a change names only the kinds it changed")
    func onlyChangedKindsAreReached() {
        let shop = ObjectsKey(connectionId: connectionId, database: "shop", schema: nil)

        let result = plan(CatalogChange(connectionId: connectionId, kinds: .triggers), keys: [shop])

        #expect(result.triggers == [shop])
        #expect(result.tables.isEmpty && result.routines.isEmpty && result.types.isEmpty)
        #expect(!result.refreshesDatabaseList)
    }

    @Test("a scoped change leaves other databases, schemas and connections alone")
    func scopedChangeStaysInItsScope() {
        let publicKey = ObjectsKey(connectionId: connectionId, database: "shop", schema: "public")
        let billing = ObjectsKey(connectionId: connectionId, database: "shop", schema: "billing")
        let warehouse = ObjectsKey(connectionId: connectionId, database: "warehouse", schema: "public")
        let otherConnection = ObjectsKey(connectionId: UUID(), database: "shop", schema: "public")

        let result = plan(
            CatalogChange(connectionId: connectionId, database: "shop", schema: "public", kinds: .tables),
            keys: [publicKey, billing, warehouse, otherConnection]
        )

        #expect(result.tables == [publicKey])
    }

    @Test("the database list refreshes only once something loaded it")
    func databaseListNeedsToBeLoaded() {
        let change = CatalogChange(connectionId: connectionId, kinds: .databases)

        #expect(plan(change, keys: []).refreshesDatabaseList)
        #expect(!plan(change, hasDatabaseList: false, keys: []).refreshesDatabaseList)
    }

    @Test("a schema change reaches the loaded schema lists of its database")
    func schemaListsFollowTheirDatabase() {
        let shop = DatabaseKey(connectionId: connectionId, database: "shop")
        let warehouse = DatabaseKey(connectionId: connectionId, database: "warehouse")

        let result = plan(
            CatalogChange(connectionId: connectionId, database: "shop", kinds: .schemas),
            keys: [],
            schemaLists: [shop, warehouse]
        )

        #expect(result.schemaLists == [shop])
    }
}
