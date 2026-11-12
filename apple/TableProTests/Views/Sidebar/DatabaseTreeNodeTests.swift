import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DatabaseTreeNodeTests {
    private func tableRef(_ name: String, schema: String? = "public") -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(database: "shop", schema: schema, table: TableInfo(name: name, type: .table, rowCount: 0))
    }

    private func objectGroup(
        database: String = "shop",
        schema: String? = "public",
        kind: SidebarObjectKind = .table
    ) -> DatabaseTreeObjectGroup {
        DatabaseTreeObjectGroup(database: database, schema: schema, kind: kind)
    }

    @Test("identity helpers are unique across kinds and stable")
    func identityHelpers() {
        let databaseId = DatabaseTreeNode.databaseId("shop")
        let schemaId = DatabaseTreeNode.schemaId(database: "shop", schema: "public")
        let tableId = DatabaseTreeNode.tableId(tableRef("users"))
        let tableGroupId = DatabaseTreeNode.containerObjectKindSectionId(objectGroup())
        let otherSchemaGroupId = DatabaseTreeNode.containerObjectKindSectionId(objectGroup(schema: "audit"))

        #expect(databaseId == DatabaseTreeNode.databaseId("shop"))
        #expect(Set([databaseId, schemaId, tableId, tableGroupId, otherSchemaGroupId]).count == 5)
    }

    @Test("A pipe inside a database or schema name does not merge two object rows")
    func pipeInsideContainerNameKeepsRowsApart() {
        let routine = RoutineInfo(name: "f", kind: .function)
        let trigger = TriggerInfo(name: "audit", timing: "AFTER", event: "INSERT", statement: "")
        let type = UserDefinedTypeInfo(name: "mood", kind: .enumeration)

        let routineIds = [
            DatabaseTreeRoutineRef(database: "a|b", schema: nil, routine: routine).id,
            DatabaseTreeRoutineRef(database: "a", schema: "b|", routine: routine).id
        ]
        let triggerIds = [
            DatabaseTreeTriggerRef(database: "a|b", schema: nil, trigger: trigger).id,
            DatabaseTreeTriggerRef(database: "a", schema: "b|", trigger: trigger).id
        ]
        let typeIds = [
            DatabaseTreeUserTypeRef(database: "a|b", schema: nil, type: type).id,
            DatabaseTreeUserTypeRef(database: "a", schema: "b|", type: type).id
        ]

        #expect(Set(routineIds).count == 2)
        #expect(Set(triggerIds).count == 2)
        #expect(Set(typeIds).count == 2)
        #expect(
            DatabaseTreeRoutineRef(database: "shop", schema: "public", routine: routine).id
                == "shop|public|FUNCTION_f"
        )
    }

    @Test("A table row keeps its id apart from one whose schema holds the period instead")
    func periodInsideTableNameKeepsTableRowsApart() {
        let dottedTable = DatabaseTreeTableRef(
            database: "shop", schema: nil, table: TableInfo(name: "b.c", type: .table, rowCount: 0, schema: "a")
        )
        let dottedSchema = DatabaseTreeTableRef(
            database: "shop", schema: nil, table: TableInfo(name: "c", type: .table, rowCount: 0, schema: "a.b")
        )
        #expect(dottedTable.id != dottedSchema.id)
        #expect(DatabaseTreeNode.tableId(dottedTable) != DatabaseTreeNode.tableId(dottedSchema))
        #expect(tableRef("users").id == "shop|public|users_TABLE")
    }

    private func partitionRef(
        _ name: String,
        parent: String = "orders",
        schema: String? = nil,
        relationType: TableInfo.TableType? = .table,
        isSubpartitioned: Bool = false,
        parentPartitionName: String? = nil
    ) -> DatabaseTreePartitionRef {
        DatabaseTreePartitionRef(
            parent: DatabaseTreeTableRef(
                database: "shop",
                schema: "public",
                table: TableInfo(name: parent, type: .partitionedTable, rowCount: nil, schema: "public")
            ),
            partition: PartitionInfo(
                name: name,
                schema: schema,
                relationType: relationType,
                isSubpartitioned: isSubpartitioned,
                parentPartitionName: parentPartitionName
            )
        )
    }

    @Test("A partition row has an identity of its own, distinct from a table of the same name")
    func partitionIdsAreDistinct() {
        let partition = DatabaseTreeNode.partitionId(partitionRef("orders_2024"))
        let table = DatabaseTreeNode.tableId(tableRef("orders_2024"))
        let otherParent = DatabaseTreeNode.partitionId(partitionRef("orders_2024", parent: "invoices"))

        #expect(Set([partition, table, otherParent]).count == 3)
    }

    @Test("Two tables' partitions of the same name are two rows, which is the MySQL case")
    func sameNamedPartitionsOfDifferentParentsDiffer() {
        let first = DatabaseTreeNode.partitionId(partitionRef("p0", parent: "events", relationType: nil))
        let second = DatabaseTreeNode.partitionId(partitionRef("p0", parent: "orders", relationType: nil))

        #expect(first != second)
    }

    @Test("A subpartition is a third row again, under the partition it subdivides")
    func subpartitionIsItsOwnRow() {
        let partition = DatabaseTreeNode.partitionId(partitionRef("p0", relationType: nil))
        let subpartition = DatabaseTreeNode.partitionId(
            partitionRef("p0", relationType: nil, parentPartitionName: "p1")
        )

        #expect(partition != subpartition)
    }

    @Test("Only a partition holding subpartitions is expandable")
    func partitionExpandability() {
        let leaf = DatabaseTreeNode(
            id: "a",
            kind: .partition(partitionRef("orders_2024"))
        )
        let composite = DatabaseTreeNode(
            id: "b",
            kind: .partition(partitionRef("orders_2025", isSubpartitioned: true))
        )

        #expect(!leaf.isExpandable)
        #expect(composite.isExpandable)
    }

    @Test("A partition row is selectable and is not a section header or a container")
    func partitionRowShape() {
        let node = DatabaseTreeNode(id: "a", kind: .partition(partitionRef("orders_2024")))

        #expect(DatabaseTreeSelection.isSelectable(node.kind))
        #expect(!node.isGroupRow)
        #expect(!node.isContainer)
        #expect(node.containerRef(systemSchemas: []) == nil)
    }

    @Test("A schema row of a one-row-per-schema tree is selectable, so the keyboard can reach and open it")
    func hierarchicalSchemaRowIsSelectable() {
        let node = DatabaseTreeNode(id: "a", kind: .hierarchicalSchemaSection(schema: "HR"))

        #expect(DatabaseTreeSelection.isSelectable(node.kind))
        #expect(DatabaseTreeTypeSelect.matchString(for: node.kind) == "HR")
    }

    @Test("Type-select can land on a partition by its own name")
    func partitionMatchesTypeSelect() {
        let node = DatabaseTreeNode(id: "a", kind: .partition(partitionRef("orders_2024")))

        #expect(DatabaseTreeTypeSelect.matchString(for: node.kind) == "orders_2024")
    }

    @Test("A relation partition opens on double-click; one that is not a relation does not")
    func partitionDoubleClickFollowsAddressability() {
        let relation = DatabaseTreeNode(id: "a", kind: .partition(partitionRef("orders_2024")))
        let intraTable = DatabaseTreeNode(
            id: "b",
            kind: .partition(partitionRef("p0", relationType: nil))
        )

        #expect(DatabaseTreeDoubleClickResolver.resolve(node: relation) != .ignore)
        #expect(DatabaseTreeDoubleClickResolver.resolve(node: intraTable) == .ignore)
    }

    @Test("status ids are unique per parent and per status")
    func statusIds() {
        let loading = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .loading)
        let empty = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .empty)
        let errored = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .error("x"))
        let otherParent = DatabaseTreeNode.statusId(parentId: "db\u{1}other", status: .loading)

        #expect(Set([loading, empty, errored, otherParent]).count == 4)
    }

    /// Only the buckets the app invented are group rows. AppKit stops indenting a group row's
    /// children, so a real container listed here would flatten the tree under it.
    @Test("Invented buckets are section headers, real database objects are not")
    func sectionHeaders() {
        func node(_ kind: DatabaseTreeNode.Kind) -> DatabaseTreeNode {
            DatabaseTreeNode(id: "n", kind: kind)
        }
        #expect(node(.recentSection).isGroupRow)
        #expect(node(.objectKindSection(.table)).isGroupRow)
        #expect(node(.redisKeysSection).isGroupRow)

        #expect(node(.containerObjectKindSection(objectGroup())).isGroupRow == false)
        #expect(node(.schema(database: "shop", schema: "public")).isGroupRow == false)
        #expect(node(.hierarchicalSchemaSection(schema: "analytics")).isGroupRow == false)
        #expect(node(.table(tableRef("users"))).isGroupRow == false)
        #expect(node(.status(.loading)).isGroupRow == false)
    }

    private func partitionedRef(_ name: String, schema: String? = "public") -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "shop",
            schema: schema,
            table: TableInfo(name: name, type: .partitionedTable, rowCount: 0)
        )
    }

    @Test("database, schema, and partitioned table nodes are expandable")
    func expandable() {
        let database = DatabaseTreeNode(id: "d", kind: .database(.minimal(name: "shop")))
        let schema = DatabaseTreeNode(id: "s", kind: .schema(database: "shop", schema: "public"))
        let table = DatabaseTreeNode(id: "t", kind: .table(tableRef("users")))
        let status = DatabaseTreeNode(id: "x", kind: .status(.loading))
        let objectGroup = DatabaseTreeNode(id: "g", kind: .containerObjectKindSection(objectGroup()))

        #expect(database.isExpandable)
        #expect(schema.isExpandable)
        #expect(objectGroup.isExpandable)
        #expect(!table.isExpandable)
        #expect(!status.isExpandable)
    }

    @Test("a partitioned table expands but its partitions and other kinds do not")
    func partitionedTableExpandable() {
        let parent = DatabaseTreeNode(id: "p", kind: .table(partitionedRef("orders")))
        let leafPartition = DatabaseTreeNode(id: "c", kind: .table(tableRef("orders_2024_01")))
        let subpartitioned = DatabaseTreeNode(id: "sp", kind: .table(partitionedRef("orders_2024_02")))
        let recent = DatabaseTreeNode(id: "r", kind: .recentTable(partitionedRef("orders")))

        #expect(parent.isExpandable)
        #expect(!leafPartition.isExpandable)
        #expect(subpartitioned.isExpandable)
        #expect(!recent.isExpandable)
    }

    @Test("a partition child gets its own node identity, distinct from its parent")
    func partitionChildIdentity() {
        let parentId = DatabaseTreeNode.tableId(partitionedRef("orders"))
        let childId = DatabaseTreeNode.tableId(tableRef("orders_2024_01"))
        #expect(parentId != childId)
    }

    @Test("tableRef is returned only for table nodes")
    func tableRefExtraction() {
        let ref = tableRef("users")
        let table = DatabaseTreeNode(id: "t", kind: .table(ref))
        let schema = DatabaseTreeNode(id: "s", kind: .schema(database: "shop", schema: "public"))

        #expect(table.tableRef == ref)
        #expect(schema.tableRef == nil)
    }

    /// A driver can return an object kind its plugin never declared a capability for. The tree lists
    /// what came back, because a folder the user cannot see is indistinguishable from a table that
    /// does not exist.
    @Test("Tree object groups follow kind order and never drop a returned object")
    func objectGroupResolution() {
        let groups = DatabaseTreeObjectGroupResolver.groups(
            database: "shop",
            schema: "public",
            itemCounts: [.table: 2, .view: 1, .materializedView: 1, .foreignTable: 1, .procedure: 1, .function: 1]
        )

        #expect(groups.map(\.kind) == [.table, .view, .materializedView, .foreignTable, .procedure, .function])
        #expect(groups.allSatisfy { $0.database == "shop" && $0.schema == "public" })
    }

    @Test("A container holding no tables gets no Tables group")
    func emptyKindsAreOmitted() {
        let groups = DatabaseTreeObjectGroupResolver.groups(
            database: "shop",
            schema: nil,
            itemCounts: [.function: 1]
        )

        #expect(groups.map(\.kind) == [.function])
        #expect(groups.first?.schema == nil)
    }

    @Test("An empty container is empty only once every declared kind has answered")
    func emptyContainerStatus() {
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: [.loaded, .loaded]) == .empty)
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: [.loaded, .loading]) == .loading)
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: [.idle]) == .loading)
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: [.loaded, .failed("gone")]) == .error("gone"))
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: []) == .empty)
    }

    /// A group listed with no rows is there for a reason. A failed fetch says so in its group; a kind
    /// still loading or loaded empty has no group, so it has no placeholder either.
    @Test("An empty group's placeholder is its own kind's failure, and nothing else")
    func groupPlaceholderIsItsFailure() {
        let phases = DatabaseTreeSidePhases(routines: .loading, triggers: .failed("denied"), types: nil)

        #expect(phases.placeholder(for: .trigger) == .error("denied"))
        #expect(phases.placeholder(for: .procedure) == nil)
        #expect(phases.placeholder(for: .type) == nil)
        #expect(phases.placeholder(for: .table) == nil)
        #expect(phases.all == [.loading, .failed("denied")])
    }

    /// Hiding a failed kind's group would make a list the server refused read as an empty one.
    @Test("A declared kind whose fetch failed keeps its group")
    func failedKindKeepsItsGroup() {
        let phases = DatabaseTreeSidePhases(routines: .failed("denied"), triggers: .loaded, types: nil)

        #expect(phases.failedKinds(among: [.procedure, .function, .trigger, .type]) == [.procedure, .function])
        #expect(phases.failedKinds(among: [.trigger]).isEmpty)
        #expect(DatabaseTreeSidePhases(routines: .loading, triggers: nil, types: nil).failedKinds(among: [.procedure]).isEmpty)

        let groups = DatabaseTreeObjectGroupResolver.groups(
            database: "app",
            schema: "public",
            itemCounts: [.table: 2],
            keeping: phases.failedKinds(among: [.procedure, .function, .trigger])
        )
        #expect(groups.map(\.kind) == [.table, .procedure, .function])
    }

    /// A schema holding only a procedure used to read as empty on the engines that group by schema,
    /// because their schema rows listed tables and nothing else.
    @Test("A schema with no tables and one procedure gets a Procedures group and nothing else")
    func proceduresOnlySchemaGetsAGroup() {
        let groups = DatabaseTreeObjectGroupResolver.groups(
            database: "",
            schema: "HR",
            itemCounts: [.procedure: 1, .function: 0, .trigger: 0, .type: 0]
        )

        #expect(groups.map(\.kind) == [.procedure])
        #expect(groups.allSatisfy { $0.schema == "HR" })
    }

    @Test("A detail group and its rows sit under their table's id, apart from the same trigger under a schema")
    func tableDetailIdsAreScopedToTheirTable() {
        let orders = tableRef("orders")
        let dotted = DatabaseTreeTableRef(
            database: "shop", schema: nil, table: TableInfo(name: "b.c", type: .table, rowCount: 0, schema: "a")
        )
        let otherDotted = DatabaseTreeTableRef(
            database: "shop", schema: nil, table: TableInfo(name: "c", type: .table, rowCount: 0, schema: "a.b")
        )
        let columns = DatabaseTreeTableDetailGroupRef(table: orders, kind: .columns)
        let columnsId = DatabaseTreeNode.tableDetailGroupId(columns)
        let ids = [
            columnsId,
            DatabaseTreeNode.tableDetailGroupId(DatabaseTreeTableDetailGroupRef(table: orders, kind: .indexes)),
            DatabaseTreeNode.tableDetailGroupId(DatabaseTreeTableDetailGroupRef(table: tableRef("invoices"), kind: .columns)),
            DatabaseTreeNode.tableDetailGroupId(DatabaseTreeTableDetailGroupRef(table: dotted, kind: .columns)),
            DatabaseTreeNode.tableDetailGroupId(DatabaseTreeTableDetailGroupRef(table: otherDotted, kind: .columns)),
            DatabaseTreeNode.tableId(orders),
        ]

        #expect(Set(ids).count == ids.count)
        #expect(columnsId.hasPrefix(DatabaseTreeNode.tableId(orders)))

        let trigger = TriggerInfo(name: "audit", timing: "AFTER", event: "INSERT", statement: "", table: "orders")
        let schemaRow = DatabaseTreeNode.triggerId(DatabaseTreeTriggerRef(database: "shop", schema: "public", trigger: trigger))
        let triggersId = DatabaseTreeNode.tableDetailGroupId(DatabaseTreeTableDetailGroupRef(table: orders, kind: .triggers))
        #expect(DatabaseTreeNode.tableDetailId(groupId: triggersId, key: "audit") != schemaRow)
        #expect(
            DatabaseTreeNode.tableDetailId(groupId: columnsId, key: "status.loading")
                != DatabaseTreeNode.statusId(parentId: columnsId, status: .loading)
        )
    }

    @Test("Table Details opens every table but a sequence; partitions still follow their own option")
    func expandabilityFollowsTheOptions() {
        let plain = DatabaseTreeNode(id: "t", kind: .table(tableRef("users")))
        let partitioned = DatabaseTreeNode(id: "p", kind: .table(partitionedRef("orders")))
        let sequence = DatabaseTreeNode(id: "s", kind: .table(DatabaseTreeTableRef(
            database: "shop", schema: "public", table: TableInfo(name: "order_ids", type: .sequence, rowCount: nil)
        )))
        let subpartitioned = DatabaseTreeNode(id: "sp", kind: .partition(partitionRef("p1", isSubpartitioned: true)))

        #expect(!plain.isExpandable(showsPartitions: true, showsTableDetails: false))
        #expect(plain.isExpandable(showsPartitions: false, showsTableDetails: true))
        #expect(partitioned.isExpandable(showsPartitions: true, showsTableDetails: false))
        #expect(!partitioned.isExpandable(showsPartitions: false, showsTableDetails: false))
        #expect(partitioned.isExpandable(showsPartitions: false, showsTableDetails: true))
        #expect(!sequence.isExpandable(showsPartitions: true, showsTableDetails: true))
        #expect(subpartitioned.isExpandable(showsPartitions: true, showsTableDetails: true))
        #expect(!subpartitioned.isExpandable(showsPartitions: false, showsTableDetails: true))
    }

    @Test("An Option-click above a table opens it only while Table Details is off, and never a detail group")
    func optionClickReachesTablesOnlyWithoutDetails() {
        let partitioned = DatabaseTreeNode(id: "p", kind: .table(partitionedRef("orders")))
        let group = DatabaseTreeNode(
            id: "g", kind: .tableDetailGroup(DatabaseTreeTableDetailGroupRef(table: tableRef("orders"), kind: .columns))
        )
        let subpartitioned = DatabaseTreeNode(id: "sp", kind: .partition(partitionRef("p1", isSubpartitioned: true)))
        let tablesGroup = DatabaseTreeNode(id: "o", kind: .containerObjectKindSection(objectGroup()))

        #expect(partitioned.opensWithAncestor(showsTableDetails: false))
        #expect(!partitioned.opensWithAncestor(showsTableDetails: true))
        #expect(!group.opensWithAncestor(showsTableDetails: true))
        #expect(subpartitioned.opensWithAncestor(showsTableDetails: false))
        #expect(tablesGroup.opensWithAncestor(showsTableDetails: true))
    }

    @Test("A detail group expands like an object group, a detail row is a leaf, and a click opens neither")
    func detailRowShapes() {
        let orders = tableRef("orders")
        let groupKind = DatabaseTreeNode.Kind.tableDetailGroup(DatabaseTreeTableDetailGroupRef(table: orders, kind: .indexes))
        let detailKind = DatabaseTreeNode.Kind.tableDetail(
            DatabaseTreeTableDetailRef(table: orders, item: .column(TestFixtures.makeColumnInfo(name: "total")))
        )
        let group = DatabaseTreeNode(id: "g", kind: groupKind)
        let detail = DatabaseTreeNode(id: "d", kind: detailKind)

        #expect(group.isExpandable)
        #expect(!detail.isExpandable)
        #expect(!group.isGroupRow)
        #expect(!detail.isGroupRow)
        #expect(!group.isContainer)
        #expect(group.containerRef(systemSchemas: []) == nil)
        #expect(group.tableRef == nil)
        #expect(detail.tableRef == nil)
        #expect(DatabaseTreeSelection.isSelectable(groupKind))
        #expect(DatabaseTreeSelection.isSelectable(detailKind))
        #expect(DatabaseTreeTypeSelect.matchString(for: groupKind) == String(localized: "Indexes"))
        #expect(DatabaseTreeTypeSelect.matchString(for: detailKind) == "total")
    }

    // MARK: - Server objects

    private let events = SidebarServerObjectKind(
        id: "event", displayName: "Event", pluralDisplayName: "Events", iconName: "calendar.badge.clock", scope: .container
    )
    private let extensions = SidebarServerObjectKind(
        id: "extension", displayName: "Extension", pluralDisplayName: "Extensions", iconName: "puzzlepiece.extension",
        scope: .database
    )

    @Test("A container kind's group follows Types in a container and carries the declared descriptor")
    func containerKindGroupFollowsTypes() {
        let groups = DatabaseTreeObjectGroupResolver.groups(
            database: "shop",
            schema: nil,
            itemCounts: [.table: 2, .trigger: 1, .type: 1, .server(SidebarServerObjectKind(id: "event")): 3],
            declared: [events]
        )

        #expect(groups.map { $0.kind } == [.table, .trigger, .type, .server(events)])
        #expect(groups.last?.kind.pluralDisplayName == "Events")
    }

    @Test("A database kind's group lists beside the schemas only when it holds rows or failed")
    func databaseKindGroupNeedsRowsOrFailure() {
        let empty = DatabaseTreeObjectGroupResolver.groups(database: "app", schema: nil, itemCounts: [:], declared: [extensions])
        #expect(empty.isEmpty)

        let phases = DatabaseTreeSidePhases(
            routines: .idle, triggers: nil, types: nil, serverObjects: ["extension": .failed("permission denied")]
        )
        let failed = DatabaseTreeObjectGroupResolver.groups(
            database: "app",
            schema: nil,
            itemCounts: [:],
            keeping: phases.failedKinds(among: [.server(extensions)]),
            declared: [extensions]
        )
        #expect(failed.map { $0.kind } == [.server(extensions)])
        #expect(phases.placeholder(for: .server(extensions)) == .error("permission denied"))
    }

    @Test("A server kind's phase is its own fetch's, and an undeclared kind reads as loaded")
    func serverKindPhases() {
        let phases = DatabaseTreeSidePhases(
            routines: .loaded, triggers: .loaded, types: nil, serverObjects: ["event": .loading]
        )

        #expect(phases.phase(for: .server(events)) == .loading)
        #expect(phases.phase(for: .server(extensions)) == .loaded)
        #expect(phases.all == [.loaded, .loaded, .loading])
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: phases.all) == .loading)
        #expect(phases.placeholder(for: .server(events)) == nil)
    }

    @Test("A server object row is a selectable leaf with an id of its own")
    func serverObjectRowIdentity() {
        let object = ServerObjectInfo(kindId: "event", name: "nightly", schema: "shop")
        let ref = DatabaseTreeServerObjectRef(database: "shop", schema: "shop", kind: events, object: object)
        let node = DatabaseTreeNode(id: DatabaseTreeNode.serverObjectId(ref), kind: .serverObject(ref))
        let trigger = DatabaseTreeTriggerRef(
            database: "shop", schema: "shop",
            trigger: TriggerInfo(name: "nightly", timing: "AFTER", event: "INSERT", statement: "")
        )

        #expect(!node.isExpandable)
        #expect(!node.isGroupRow)
        #expect(!node.isContainer)
        #expect(DatabaseTreeSelection.isSelectable(node.kind))
        #expect(DatabaseTreeNode.serverObjectId(ref) != DatabaseTreeNode.triggerId(trigger))
        #expect(DatabaseTreeDoubleClickResolver.resolve(node: node) == .openObjectSource(ref.objectRef))
    }

    @Test("A declared kind's group id spells its persistence name, and built-in ids are unchanged")
    func serverGroupIdsUsePersistenceName() {
        #expect(DatabaseTreeNode.objectKindSectionId(.table) == "kindSection\u{1}table")
        #expect(
            DatabaseTreeNode.containerObjectKindSectionId(objectGroup(kind: .materializedView))
                == "containerKindSection\u{1}shop\u{1}public\u{1}materializedView"
        )
        #expect(DatabaseTreeNode.objectKindSectionId(.server(events)) == "kindSection\u{1}server.event")
    }
}
