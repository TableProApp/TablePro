//
//  DatabaseTreeCatalogRefreshPlanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import Testing

struct DatabaseTreeCatalogRefreshPlanTests {
    private typealias ObjectsKey = DatabaseTreeMetadataService.ObjectsKey
    private typealias DatabaseKey = DatabaseTreeMetadataService.DatabaseKey

    private let connectionId = UUID()

    private typealias PartitionsKey = DatabaseTreeMetadataService.PartitionsKey

    private func plan(
        _ change: CatalogChange,
        hasDatabaseList: Bool = true,
        keys: [ObjectsKey],
        schemaLists: [DatabaseKey] = [],
        partitions: [PartitionsKey] = []
    ) -> CatalogTreeRefreshPlan {
        DatabaseTreeMetadataService.catalogRefreshPlan(
            for: change,
            hasDatabaseList: hasDatabaseList,
            schemaListKeys: schemaLists,
            tableKeys: keys,
            partitionKeys: partitions,
            routineKeys: keys,
            triggerKeys: keys,
            typeKeys: keys
        )
    }

    /// A partition list is keyed per table and does not follow its parent's list, so planning from
    /// the table keys alone left an expanded partitioned table showing the partitions it had before
    /// the DDL until a reconnect.
    @Test("A loaded partition list is refreshed even with no table list beside it")
    func partitionListsAreReachedWithoutTheirParentList() {
        let partition = PartitionsKey(
            connectionId: connectionId, database: "shop", schema: "public", table: "events"
        )

        let result = plan(
            CatalogChange(connectionId: connectionId, kinds: .tables),
            keys: [],
            partitions: [partition]
        )

        #expect(result.partitions == [partition])
        #expect(!result.isEmpty)
    }

    /// A PostgreSQL partition can live in another schema than the table it belongs to, so matching
    /// its schema against the change would miss exactly the cross-schema case the tree nests.
    @Test("A partition list in another schema than the change still refreshes")
    func crossSchemaPartitionListsAreReached() {
        let partition = PartitionsKey(
            connectionId: connectionId, database: "shop", schema: "archive", table: "events"
        )

        let result = plan(
            CatalogChange(connectionId: connectionId, database: "shop", schema: "public", kinds: .tables),
            keys: [],
            partitions: [partition]
        )

        #expect(result.partitions == [partition])
    }

    @Test("A change that reaches no partition kind leaves partition lists alone")
    func partitionListsIgnoreUnrelatedKinds() {
        let partition = PartitionsKey(
            connectionId: connectionId, database: "shop", schema: "public", table: "events"
        )

        let result = plan(
            CatalogChange(connectionId: connectionId, kinds: .routines),
            keys: [],
            partitions: [partition]
        )

        #expect(result.partitions.isEmpty)
    }

    @Test("Another connection's partition lists are not touched")
    func otherConnectionPartitionListsAreLeftAlone() {
        let partition = PartitionsKey(
            connectionId: UUID(), database: "shop", schema: "public", table: "events"
        )

        let result = plan(
            CatalogChange(connectionId: connectionId, kinds: .tables),
            keys: [],
            partitions: [partition]
        )

        #expect(result.partitions.isEmpty)
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

    private func allSchemaPlan(_ change: CatalogChange, keys: [DatabaseKey]) -> CatalogTreeRefreshPlan {
        DatabaseTreeMetadataService.catalogRefreshPlan(
            for: change,
            hasDatabaseList: false,
            schemaListKeys: [DatabaseKey](),
            tableKeys: [ObjectsKey](),
            routineKeys: [ObjectsKey](),
            triggerKeys: [ObjectsKey](),
            typeKeys: [ObjectsKey](),
            allSchemaTableKeys: keys
        )
    }

    @Test("a table or schema change reaches the all-schema listing of its database only")
    func allSchemaListingFollowsItsDatabase() {
        let shop = DatabaseKey(connectionId: connectionId, database: "shop")
        let warehouse = DatabaseKey(connectionId: connectionId, database: "warehouse")
        let other = DatabaseKey(connectionId: UUID(), database: "shop")

        let tables = allSchemaPlan(
            CatalogChange(connectionId: connectionId, database: "shop", kinds: .tables),
            keys: [shop, warehouse, other]
        )
        let schemas = allSchemaPlan(CatalogChange(connectionId: connectionId, kinds: .schemas), keys: [shop, warehouse])

        #expect(tables.allSchemaTables == [shop])
        #expect(schemas.allSchemaTables == [shop, warehouse])
        #expect(!tables.isEmpty)
    }

    @Test("a change that cannot touch a table leaves the all-schema listing alone")
    func routineChangeLeavesAllSchemaListing() {
        let shop = DatabaseKey(connectionId: connectionId, database: "shop")

        let result = allSchemaPlan(CatalogChange(connectionId: connectionId, kinds: .routines), keys: [shop])

        #expect(result.allSchemaTables.isEmpty)
        #expect(result.isEmpty)
    }

    private typealias TableDetailsKey = DatabaseTreeMetadataService.TableDetailsKey

    private func detailKey(
        _ kind: TableDetailKind,
        database: String = "shop",
        schema: String? = "public",
        connection: UUID? = nil
    ) -> TableDetailsKey {
        TableDetailsKey(connectionId: connection ?? connectionId, database: database, schema: schema, table: "orders", kind: kind)
    }

    private func detailPlan(_ change: CatalogChange, keys: [TableDetailsKey]) -> CatalogTreeRefreshPlan {
        DatabaseTreeMetadataService.catalogRefreshPlan(
            for: change,
            hasDatabaseList: false,
            schemaListKeys: [DatabaseKey](),
            tableKeys: [ObjectsKey](),
            tableDetailKeys: keys,
            routineKeys: [ObjectsKey](),
            triggerKeys: [ObjectsKey](),
            typeKeys: [ObjectsKey]()
        )
    }

    /// A foreign key in one schema can point at a table another schema's DDL just dropped, so a
    /// table change reaches the whole database, the way partition lists are reached.
    @Test("A table change reaches every detail list of its database, in any schema")
    func tableChangeReachesDetailLists() {
        let columns = detailKey(.columns)
        let auditTriggers = detailKey(.triggers, schema: "audit")
        let otherDatabase = detailKey(.columns, database: "warehouse")
        let otherConnection = detailKey(.columns, connection: UUID())

        let result = detailPlan(
            CatalogChange(connectionId: connectionId, database: "shop", schema: "public", kinds: .tables),
            keys: [columns, auditTriggers, otherDatabase, otherConnection]
        )

        #expect(result.tableDetails == [columns, auditTriggers])
        #expect(!result.isEmpty)
    }

    @Test("A trigger change reaches trigger lists alone, and a routine change reaches none")
    func triggerChangeReachesTriggerLists() {
        let columns = detailKey(.columns)
        let triggers = detailKey(.triggers)

        let triggerPlan = detailPlan(CatalogChange(connectionId: connectionId, kinds: .triggers), keys: [columns, triggers])
        let routinePlan = detailPlan(CatalogChange(connectionId: connectionId, kinds: .routines), keys: [columns, triggers])

        #expect(triggerPlan.tableDetails == [triggers])
        #expect(routinePlan.tableDetails.isEmpty)
        #expect(routinePlan.isEmpty)
    }

    private typealias ServerObjectsKey = DatabaseTreeMetadataService.ServerObjectsKey

    private func serverObjectPlan(_ change: CatalogChange, keys: [ServerObjectsKey]) -> CatalogTreeRefreshPlan {
        DatabaseTreeMetadataService.catalogRefreshPlan(
            for: change,
            hasDatabaseList: false,
            schemaListKeys: [],
            tableKeys: [],
            routineKeys: [],
            triggerKeys: [],
            typeKeys: [],
            serverObjectKeys: keys
        )
    }

    @Test("An event change marks the container's events stale and leaves another database current")
    func eventChangeReachesItsContainer() {
        let shopEvents = ServerObjectsKey(connectionId: connectionId, database: "shop", schema: nil, kindId: "event")
        let warehouseEvents = ServerObjectsKey(connectionId: connectionId, database: "warehouse", schema: nil, kindId: "event")
        let otherConnection = ServerObjectsKey(connectionId: UUID(), database: "shop", schema: nil, kindId: "event")

        let result = serverObjectPlan(
            CatalogChange(connectionId: connectionId, database: "shop", kinds: [.triggers, .serverObjects]),
            keys: [shopEvents, warehouseEvents, otherConnection]
        )

        #expect(result.serverObjects == [shopEvents])
        #expect(!result.isEmpty)
    }

    @Test("A database-wide list is reached by a change made in any of its schemas")
    func databaseScopedListIsReachedFromASchema() {
        let extensions = ServerObjectsKey(connectionId: connectionId, database: "app", schema: nil, kindId: "extension")
        let auditEvents = ServerObjectsKey(connectionId: connectionId, database: "app", schema: "audit", kindId: "event")

        let result = serverObjectPlan(
            CatalogChange(connectionId: connectionId, database: "app", schema: "public", kinds: .objects),
            keys: [extensions, auditEvents]
        )

        #expect(result.serverObjects == [extensions])
    }

    @Test("A container lists the declared kinds of its own level")
    func serverKindsFollowTheContainerLevel() {
        let events = SidebarServerObjectKind(
            id: "event", displayName: "Event", pluralDisplayName: "Events", iconName: "calendar.badge.clock", scope: .container
        )
        let extensions = SidebarServerObjectKind(
            id: "extension", displayName: "Extension", pluralDisplayName: "Extensions", iconName: "puzzlepiece.extension",
            scope: .database
        )
        let declared = [events, extensions]

        #expect(DatabaseTreeMetadataService.serverKinds(declared: declared, schema: "public", listsTablesPerSchema: true) == [events])
        #expect(DatabaseTreeMetadataService.serverKinds(declared: declared, schema: nil, listsTablesPerSchema: true) == [extensions])
        #expect(DatabaseTreeMetadataService.serverKinds(declared: declared, schema: nil, listsTablesPerSchema: false) == declared)
        #expect(DatabaseTreeMetadataService.serverKinds(declared: declared, schema: "", listsTablesPerSchema: true) == [extensions])
    }

    @Test("A change that names no server object kind leaves those lists current")
    func unrelatedChangeLeavesServerObjects() {
        let shopEvents = ServerObjectsKey(connectionId: connectionId, database: "shop", schema: nil, kindId: "event")

        let result = serverObjectPlan(CatalogChange(connectionId: connectionId, database: "shop", kinds: .tables), keys: [shopEvents])

        #expect(result.serverObjects.isEmpty)
        #expect(result.isEmpty)
    }
}
