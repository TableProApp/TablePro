// A table edited in the diagram is drawn from its working copy until the save lands, so what is
// about to change stays visible and marked.

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ERDiagramStagedOverlayTests {
    private func savedGraph() -> ERDiagramGraph {
        ERDiagramGraphBuilder.build(
            allColumns: [
                "customers": [
                    ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
                    ColumnInfo(name: "email", dataType: "text", isNullable: true, isPrimaryKey: false)
                ],
                "orders": [
                    ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
                    ColumnInfo(name: "customer_id", dataType: "integer", isNullable: false, isPrimaryKey: false),
                    ColumnInfo(name: "shipper_id", dataType: "integer", isNullable: true, isPrimaryKey: false)
                ],
                "shippers": [ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true)]
            ],
            allForeignKeys: [
                "orders": [
                    ForeignKeyInfo(name: "orders_shipper_fk", column: "shipper_id", referencedTable: "shippers", referencedColumn: "id")
                ]
            ]
        )
    }

    private func manager(for table: String, in graph: ERDiagramGraph) -> StructureChangeManager {
        let manager = StructureChangeManager()
        let node = graph.nodes.first { $0.tableName == table }
        let foreignKeys = graph.edges.filter { $0.fromTable == table }.map {
            ForeignKeyInfo(name: $0.fkName, column: $0.fromColumn, referencedTable: $0.toTable, referencedColumn: $0.toColumn)
        }
        manager.loadSchema(
            tableName: table,
            columns: (node?.columns ?? []).map {
                ColumnInfo(name: $0.name, dataType: $0.dataType, isNullable: $0.isNullable, isPrimaryKey: $0.isPrimaryKey)
            },
            indexes: [],
            foreignKeys: foreignKeys,
            primaryKey: (node?.columns ?? []).filter(\.isPrimaryKey).map(\.name)
        )
        return manager
    }

    @Test("Nothing staged draws the saved graph unchanged")
    func nothingStagedKeepsTheSavedGraph() {
        let graph = savedGraph()
        let overlaid = ERDiagramStagedOverlay.apply([:], to: graph)

        let savedIds = graph.edges.map { $0.id }
        #expect(overlaid.edges.map { $0.id } == savedIds)
        let columns = overlaid.nodes.flatMap { $0.columns }
        #expect(columns.allSatisfy { $0.stagedEdit == nil })
    }

    @Test("A staged key is drawn as an added edge, and a dropped key stays drawn, marked")
    func stagedKeysAreMarked() throws {
        let graph = savedGraph()
        let orders = manager(for: "orders", in: graph)
        var foreignKey = EditableForeignKeyDefinition.placeholder()
        foreignKey.name = "fk_orders_customer_id"
        foreignKey.columns = ["customer_id"]
        foreignKey.referencedTable = "customers"
        foreignKey.referencedColumns = ["id"]
        orders.addForeignKey(foreignKey)
        let shipper = try #require(orders.workingForeignKeys.first { $0.name == "orders_shipper_fk" })
        orders.deleteForeignKey(id: shipper.id)

        let overlaid = ERDiagramStagedOverlay.apply(
            ["orders": ERDiagramStagedOverlay.TableEdits(orders)], to: graph
        )

        let added = try #require(overlaid.edges.first { $0.fkName == "fk_orders_customer_id" })
        #expect(added.stagedEdit == .added)
        #expect(added.toTable == "customers")
        #expect(added.cardinality == .manyToOne)
        let dropped = try #require(overlaid.edges.first { $0.fkName == "orders_shipper_fk" })
        #expect(dropped.stagedEdit == .dropped)
        let saved = try #require(graph.edges.first { $0.fkName == "orders_shipper_fk" })
        #expect(dropped.id == saved.id)
    }

    @Test("Added, renamed and dropped columns are marked on their table")
    func stagedColumnsAreMarked() throws {
        let graph = savedGraph()
        let customers = manager(for: "customers", in: graph)
        var notes = EditableColumnDefinition.placeholder()
        notes.name = "notes"
        notes.dataType = "text"
        customers.addColumn(notes)
        var email = try #require(customers.workingColumns.first { $0.name == "email" })
        email.name = "contact_email"
        customers.updateColumn(id: email.id, with: email)
        let id = try #require(customers.workingColumns.first { $0.name == "id" })
        customers.deleteColumn(id: id.id)

        let overlaid = ERDiagramStagedOverlay.apply(
            ["customers": ERDiagramStagedOverlay.TableEdits(customers)], to: graph
        )
        let node = try #require(overlaid.nodes.first { $0.tableName == "customers" })

        #expect(node.columns.map { $0.name } == ["id", "contact_email", "notes"])
        #expect(node.columns.map { $0.stagedEdit } == [.dropped, .modified, .added])
        #expect(node.id == graph.nodeIndex["customers"])
    }

    @Test("A renamed key column keeps its key badge, and its relationship shows the new name")
    func renamedKeyColumnKeepsItsKey() throws {
        let graph = savedGraph()
        let orders = manager(for: "orders", in: graph)
        var shipper = try #require(orders.workingColumns.first { $0.name == "shipper_id" })
        shipper.name = "carrier_id"
        orders.updateColumn(id: shipper.id, with: shipper)

        let overlaid = ERDiagramStagedOverlay.apply(["orders": ERDiagramStagedOverlay.TableEdits(orders)], to: graph)

        let node = try #require(overlaid.nodes.first { $0.tableName == "orders" })
        #expect(node.columns.first { $0.name == "carrier_id" }?.isForeignKey == true)
        let edge = try #require(overlaid.edges.first { $0.fkName == "orders_shipper_fk" })
        #expect(edge.fromColumn == "carrier_id")
    }

    @Test("A key added in place of a dropped one with the same name is its own relationship")
    func replacementKeyHasItsOwnIdentity() throws {
        let graph = savedGraph()
        let orders = manager(for: "orders", in: graph)
        let shipper = try #require(orders.workingForeignKeys.first { $0.name == "orders_shipper_fk" })
        orders.deleteForeignKey(id: shipper.id)
        var replacement = EditableForeignKeyDefinition.placeholder()
        replacement.name = "orders_shipper_fk"
        replacement.columns = ["shipper_id"]
        replacement.referencedTable = "customers"
        replacement.referencedColumns = ["id"]
        orders.addForeignKey(replacement)

        let overlaid = ERDiagramStagedOverlay.apply(["orders": ERDiagramStagedOverlay.TableEdits(orders)], to: graph)
        let drawn = overlaid.edges.filter { $0.fkName == "orders_shipper_fk" }

        #expect(drawn.count == 2)
        #expect(Set(drawn.map { $0.id }).count == 2)
        #expect(drawn.first { $0.stagedEdit == .added }?.toTable == "customers")
    }

    @Test("A key added on a table's only primary key column is drawn one-to-one")
    func keyOnThePrimaryKeyIsOneToOne() throws {
        let graph = savedGraph()
        let customers = manager(for: "customers", in: graph)
        var foreignKey = EditableForeignKeyDefinition.placeholder()
        foreignKey.name = "fk_customers_id"
        foreignKey.columns = ["id"]
        foreignKey.referencedTable = "shippers"
        foreignKey.referencedColumns = ["id"]
        customers.addForeignKey(foreignKey)

        let overlaid = ERDiagramStagedOverlay.apply(
            ["customers": ERDiagramStagedOverlay.TableEdits(customers)], to: graph
        )

        #expect(overlaid.edges.first { $0.fkName == "fk_customers_id" }?.cardinality == .oneToOne)
    }

    @Test("An edited junction table is drawn expanded, so its staged keys stay visible")
    func editedJunctionTableStaysExpanded() throws {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true)],
                "roles": [ColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true)],
                "user_roles": [
                    ColumnInfo(name: "user_id", dataType: "integer", isNullable: false, isPrimaryKey: true),
                    ColumnInfo(name: "role_id", dataType: "integer", isNullable: false, isPrimaryKey: true)
                ]
            ],
            allForeignKeys: [
                "user_roles": [
                    ForeignKeyInfo(name: "ur_user", column: "user_id", referencedTable: "users", referencedColumn: "id"),
                    ForeignKeyInfo(name: "ur_role", column: "role_id", referencedTable: "roles", referencedColumn: "id")
                ]
            ]
        )
        let junction = manager(for: "user_roles", in: graph)
        let key = try #require(junction.workingForeignKeys.first { $0.name == "ur_role" })
        junction.deleteForeignKey(id: key.id)

        let collapsed = ERDiagramStagedOverlay.apply(
            ["user_roles": ERDiagramStagedOverlay.TableEdits(junction)], to: graph
        ).projected(collapseJunctions: true)

        #expect(collapsed.nodeIndex["user_roles"] != nil)
        #expect(collapsed.edges.first { $0.fkName == "ur_role" }?.stagedEdit == .dropped)
        #expect(!collapsed.edges.contains { $0.cardinality == .manyToMany })
    }
}
