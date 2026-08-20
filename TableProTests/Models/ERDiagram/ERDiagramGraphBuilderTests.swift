//
//  ERDiagramGraphBuilderTests.swift
//  TableProTests
//
//  Tests relationship cardinality inference and junction-table detection.
//

import Foundation
@testable import TablePro
import Testing

@Suite("ER diagram graph builder")
struct ERDiagramGraphBuilderTests {
    private func column(
        _ name: String,
        type: String = "integer",
        nullable: Bool = false,
        primaryKey: Bool = false
    ) -> ColumnInfo {
        ColumnInfo(name: name, dataType: type, isNullable: nullable, isPrimaryKey: primaryKey)
    }

    private func foreignKey(
        _ name: String = "fk",
        column: String,
        references table: String,
        _ refColumn: String = "id"
    ) -> ForeignKeyInfo {
        ForeignKeyInfo(name: name, column: column, referencedTable: table, referencedColumn: refColumn)
    }

    private func uniqueIndex(_ name: String, columns: [String]) -> IndexInfo {
        IndexInfo(name: name, columns: columns, isUnique: true, isPrimary: false, type: "BTREE")
    }

    private func cardinality(from table: String, in graph: ERDiagramGraph) -> ERCardinality? {
        graph.edges.first { $0.fromTable == table && $0.cardinality != .manyToMany }?.cardinality
    }

    private func isJunction(_ table: String, in graph: ERDiagramGraph) -> Bool {
        guard let node = graph.nodes.first(where: { $0.tableName == table }) else { return false }
        return node.isJunctionTable
    }

    // MARK: - Cardinality

    @Test("Primary-key foreign key that is NOT NULL is one-to-one")
    func primaryKeyFKIsOneToOne() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "user_settings": [column("user_id", nullable: false, primaryKey: true)]
            ],
            allForeignKeys: ["user_settings": [foreignKey(column: "user_id", references: "users")]]
        )
        #expect(cardinality(from: "user_settings", in: graph) == .oneToOne)
    }

    @Test("Single-column unique index on a NOT NULL foreign key is one-to-one")
    func uniqueIndexedFKIsOneToOne() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "profiles": [column("id", primaryKey: true), column("user_id", nullable: false)]
            ],
            allForeignKeys: ["profiles": [foreignKey(column: "user_id", references: "users")]],
            allIndexes: ["profiles": [uniqueIndex("uq_user", columns: ["user_id"])]]
        )
        #expect(cardinality(from: "profiles", in: graph) == .oneToOne)
    }

    @Test("Unique index on a nullable foreign key is zero-or-one-to-one")
    func nullableUniqueFKIsZeroOrOneToOne() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "profiles": [column("id", primaryKey: true), column("user_id", nullable: true)]
            ],
            allForeignKeys: ["profiles": [foreignKey(column: "user_id", references: "users")]],
            allIndexes: ["profiles": [uniqueIndex("uq_user", columns: ["user_id"])]]
        )
        #expect(cardinality(from: "profiles", in: graph) == .zeroOrOneToOne)
    }

    @Test("Non-unique NOT NULL foreign key is many-to-one")
    func notNullNonUniqueFKIsManyToOne() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "orders": [column("id", primaryKey: true), column("user_id", nullable: false)]
            ],
            allForeignKeys: ["orders": [foreignKey(column: "user_id", references: "users")]]
        )
        #expect(cardinality(from: "orders", in: graph) == .manyToOne)
    }

    @Test("Non-unique nullable foreign key is zero-or-many-to-one")
    func nullableNonUniqueFKIsZeroOrManyToOne() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "orders": [column("id", primaryKey: true), column("user_id", nullable: true)]
            ],
            allForeignKeys: ["orders": [foreignKey(column: "user_id", references: "users")]]
        )
        #expect(cardinality(from: "orders", in: graph) == .zeroOrManyToOne)
    }

    @Test("Composite unique index does not make a single column one-to-one")
    func compositeUniqueIndexIsNotOneToOne() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "memberships": [
                    column("id", primaryKey: true),
                    column("user_id", nullable: false),
                    column("org_id", nullable: false)
                ]
            ],
            allForeignKeys: ["memberships": [foreignKey(column: "user_id", references: "users")]],
            allIndexes: ["memberships": [uniqueIndex("uq_user_org", columns: ["user_id", "org_id"])]]
        )
        #expect(cardinality(from: "memberships", in: graph) == .manyToOne)
    }

    @Test("A partial unique index does not make a column one-to-one")
    func partialUniqueIndexIsNotOneToOne() {
        let partialIndex = IndexInfo(
            name: "uq_active_user",
            columns: ["user_id"],
            isUnique: true,
            isPrimary: false,
            type: "BTREE",
            whereClause: "deleted_at IS NULL"
        )
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "profiles": [column("id", primaryKey: true), column("user_id", nullable: false)]
            ],
            allForeignKeys: ["profiles": [foreignKey(column: "user_id", references: "users")]],
            allIndexes: ["profiles": [partialIndex]]
        )
        #expect(cardinality(from: "profiles", in: graph) == .manyToOne)
    }

    @Test("A foreign key that is only part of a composite primary key is many-to-one")
    func compositePrimaryKeyMemberIsNotOneToOne() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "audit": [
                    column("user_id", nullable: false, primaryKey: true),
                    column("seq", nullable: false, primaryKey: true)
                ]
            ],
            allForeignKeys: ["audit": [foreignKey(column: "user_id", references: "users")]]
        )
        #expect(cardinality(from: "audit", in: graph) == .manyToOne)
    }

    @Test("Junction edges are many-to-one in the expanded graph")
    func junctionEdgesAreManyToOne() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "roles": [column("id", primaryKey: true)],
                "user_roles": [
                    column("user_id", nullable: false, primaryKey: true),
                    column("role_id", nullable: false, primaryKey: true)
                ]
            ],
            allForeignKeys: ["user_roles": [
                foreignKey("fk_user", column: "user_id", references: "users"),
                foreignKey("fk_role", column: "role_id", references: "roles")
            ]]
        )
        let junctionEdges = graph.edges.filter { $0.fromTable == "user_roles" }
        #expect(junctionEdges.count == 2)
        #expect(junctionEdges.allSatisfy { $0.cardinality == .manyToOne })
    }

    @Test("Missing column metadata falls back to zero-or-many-to-one")
    func missingColumnFallsBack() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "orders": [column("id", primaryKey: true)]
            ],
            allForeignKeys: ["orders": [foreignKey(column: "user_id", references: "users")]]
        )
        #expect(cardinality(from: "orders", in: graph) == .zeroOrManyToOne)
    }

    // MARK: - Junction detection

    @Test("A table whose composite PK is two FKs is a junction table")
    func junctionTableDetected() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "roles": [column("id", primaryKey: true)],
                "user_roles": [
                    column("user_id", primaryKey: true),
                    column("role_id", primaryKey: true)
                ]
            ],
            allForeignKeys: ["user_roles": [
                foreignKey("fk_user", column: "user_id", references: "users"),
                foreignKey("fk_role", column: "role_id", references: "roles")
            ]]
        )
        #expect(isJunction("user_roles", in: graph))
        #expect(graph.manyToManyEdges.count == 1)
        let mn = graph.manyToManyEdges.first
        #expect(mn?.cardinality == .manyToMany)
        #expect([mn?.fromTable, mn?.toTable].compactMap { $0 }.sorted() == ["roles", "users"])
    }

    @Test("Composite PK with only one FK column is not a junction table")
    func partialFKCompositePKIsNotJunction() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "audit": [
                    column("user_id", primaryKey: true),
                    column("seq", primaryKey: true)
                ]
            ],
            allForeignKeys: ["audit": [foreignKey("fk_user", column: "user_id", references: "users")]]
        )
        #expect(!isJunction("audit", in: graph))
        #expect(graph.manyToManyEdges.isEmpty)
    }

    @Test("Two FK columns referencing the same table is not a junction table")
    func twoFKsSameTargetIsNotJunction() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "friendships": [
                    column("from_user", primaryKey: true),
                    column("to_user", primaryKey: true)
                ]
            ],
            allForeignKeys: ["friendships": [
                foreignKey("fk_from", column: "from_user", references: "users"),
                foreignKey("fk_to", column: "to_user", references: "users")
            ]]
        )
        #expect(!isJunction("friendships", in: graph))
        #expect(graph.manyToManyEdges.isEmpty)
    }

    @Test("A regular table with a non-PK foreign key is not a junction table")
    func regularTableIsNotJunction() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "orders": [column("id", primaryKey: true), column("user_id", nullable: false)]
            ],
            allForeignKeys: ["orders": [foreignKey(column: "user_id", references: "users")]]
        )
        #expect(!isJunction("orders", in: graph))
        #expect(graph.manyToManyEdges.isEmpty)
    }

    // MARK: - Projection

    @Test("Collapsing junctions hides the junction node and shows a many-to-many edge")
    func collapsedProjectionHidesJunction() {
        let graph = ERDiagramGraphBuilder.build(
            allColumns: [
                "users": [column("id", primaryKey: true)],
                "roles": [column("id", primaryKey: true)],
                "user_roles": [
                    column("user_id", primaryKey: true),
                    column("role_id", primaryKey: true)
                ]
            ],
            allForeignKeys: ["user_roles": [
                foreignKey("fk_user", column: "user_id", references: "users"),
                foreignKey("fk_role", column: "role_id", references: "roles")
            ]]
        )

        let collapsed = graph.projected(collapseJunctions: true)
        #expect(!collapsed.nodes.contains { $0.tableName == "user_roles" })
        #expect(collapsed.edges.count == 1)
        #expect(collapsed.edges.first?.cardinality == .manyToMany)

        let expanded = graph.projected(collapseJunctions: false)
        #expect(expanded.nodes.contains { $0.tableName == "user_roles" })
        #expect(expanded.edges.count == 2)
        #expect(!expanded.edges.contains { $0.cardinality == .manyToMany })
    }
}
