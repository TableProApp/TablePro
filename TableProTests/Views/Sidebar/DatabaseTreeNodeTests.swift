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

    /// A section with no rows was drawn bare, so a Procedures section still waiting on its fetch, one
    /// whose fetch failed, and one that is genuinely empty all looked the same.
    @Test("An empty section says whether it is loading, failed or empty")
    func emptySectionStatus() {
        #expect(DatabaseTreeNode.Status.emptySection(.idle) == .loading)
        #expect(DatabaseTreeNode.Status.emptySection(.loading) == .loading)
        #expect(DatabaseTreeNode.Status.emptySection(.failed("denied")) == .error("denied"))
        #expect(DatabaseTreeNode.Status.emptySection(.loaded) == .empty)
    }

    @Test("An empty container is empty only once every declared kind has answered")
    func emptyContainerStatus() {
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: [.loaded, .loaded]) == .empty)
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: [.loaded, .loading]) == .loading)
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: [.idle]) == .loading)
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: [.loaded, .failed("gone")]) == .error("gone"))
        #expect(DatabaseTreeNode.Status.emptyContainer(sideStates: []) == .empty)
    }

    /// An empty group used to say "No items" while its kind was still loading, and a failed fetch
    /// showed that same false "No items" with the error pushed up to the container.
    @Test("An empty group's placeholder follows its own kind's fetch")
    func groupPlaceholderFollowsItsKind() {
        let phases = DatabaseTreeSidePhases(routines: .loading, triggers: .failed("denied"), types: nil)

        #expect(DatabaseTreeNode.Status.emptySection(phases.phase(for: .routine)) == .loading)
        #expect(DatabaseTreeNode.Status.emptySection(phases.phase(for: .trigger)) == .error("denied"))
        #expect(DatabaseTreeNode.Status.emptySection(phases.phase(for: .type)) == .empty)
        #expect(DatabaseTreeNode.Status.emptySection(phases.phase(for: .table)) == .empty)
        #expect(phases.all == [.loading, .failed("denied")])
    }

    @Test("A failure goes on the container only when no group of its kind is listed")
    func unplacedFailureOnlyWithoutAGroup() {
        let phases = DatabaseTreeSidePhases(routines: .failed("denied"), triggers: .loaded, types: nil)

        #expect(phases.unplacedFailure(listing: [.table, .routine]) == nil)
        #expect(phases.unplacedFailure(listing: [.table]) == "denied")
        #expect(DatabaseTreeSidePhases(routines: .loaded, triggers: nil, types: nil).unplacedFailure(listing: []) == nil)
    }

    /// A schema holding only a procedure used to read as empty on the engines that group by schema,
    /// because their schema rows listed tables and nothing else.
    @Test("A schema with no tables and one procedure gets a Procedures group")
    func proceduresOnlySchemaGetsAGroup() {
        let groups = DatabaseTreeObjectGroupResolver.groups(
            database: "",
            schema: "HR",
            itemCounts: [.procedure: 1],
            declaredKinds: [.procedure, .function]
        )

        #expect(groups.map(\.kind) == [.procedure, .function])
        #expect(groups.allSatisfy { $0.schema == "HR" })
    }
}
