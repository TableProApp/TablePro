import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseTreeNode")
struct DatabaseTreeNodeTests {
    private func tableRef(_ name: String, schema: String? = "public") -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(database: "shop", schema: schema, table: TableInfo(name: name, type: .table, rowCount: 0))
    }

    @Test("identity helpers are unique across kinds and stable")
    func identityHelpers() {
        let databaseId = DatabaseTreeNode.databaseId("shop")
        let schemaId = DatabaseTreeNode.schemaId(database: "shop", schema: "public")
        let tableId = DatabaseTreeNode.tableId(tableRef("users"))

        #expect(databaseId == DatabaseTreeNode.databaseId("shop"))
        #expect(Set([databaseId, schemaId, tableId]).count == 3)
    }

    @Test("status ids are unique per parent and per status")
    func statusIds() {
        let loading = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .loading)
        let empty = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .empty)
        let errored = DatabaseTreeNode.statusId(parentId: "db\u{1}shop", status: .error("x"))
        let otherParent = DatabaseTreeNode.statusId(parentId: "db\u{1}other", status: .loading)

        #expect(Set([loading, empty, errored, otherParent]).count == 4)
    }

    @Test("only database and schema nodes are expandable")
    func expandable() {
        let database = DatabaseTreeNode(id: "d", kind: .database(.minimal(name: "shop")))
        let schema = DatabaseTreeNode(id: "s", kind: .schema(database: "shop", schema: "public"))
        let table = DatabaseTreeNode(id: "t", kind: .table(tableRef("users")))
        let status = DatabaseTreeNode(id: "x", kind: .status(.loading))

        #expect(database.isExpandable)
        #expect(schema.isExpandable)
        #expect(!table.isExpandable)
        #expect(!status.isExpandable)
    }

    @Test("tableRef is returned only for table nodes")
    func tableRefExtraction() {
        let ref = tableRef("users")
        let table = DatabaseTreeNode(id: "t", kind: .table(ref))
        let schema = DatabaseTreeNode(id: "s", kind: .schema(database: "shop", schema: "public"))

        #expect(table.tableRef == ref)
        #expect(schema.tableRef == nil)
    }
}
