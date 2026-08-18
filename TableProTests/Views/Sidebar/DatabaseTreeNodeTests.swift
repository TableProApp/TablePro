import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseTreeNode")
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
}
