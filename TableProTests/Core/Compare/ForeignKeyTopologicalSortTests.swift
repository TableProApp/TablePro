//
//  ForeignKeyTopologicalSortTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("ForeignKeyTopologicalSort")
struct ForeignKeyTopologicalSortTests {
    private func table(_ name: String, _ schema: String? = nil) -> ForeignKeyTopologicalSort.Table {
        ForeignKeyTopologicalSort.Table(name: name, schema: schema)
    }

    private func foreignKey(to referencedTable: String, schema: String? = nil) -> PluginForeignKeyInfo {
        PluginForeignKeyInfo(
            name: "fk_\(referencedTable)",
            column: "\(referencedTable)_id",
            referencedTable: referencedTable,
            referencedColumn: "id",
            referencedSchema: schema
        )
    }

    @Test("A table with no schema is identified by its bare name")
    func bareNameIsTheIdentifierWithoutASchema() {
        #expect(table("orders").identifier == "orders")
        #expect(table("orders", "").identifier == "orders")
        #expect(table("orders", "public").identifier == "public.orders")
    }

    @Test("The same table name in two schemas stays two tables")
    func sameNameInTwoSchemasStaysDistinct() {
        let ordered = ForeignKeyTopologicalSort.ordered(
            [table("orders", "public"), table("orders", "sales")],
            foreignKeysByTable: [:]
        )

        #expect(ordered.map { $0.identifier } == ["public.orders", "sales.orders"])
        #expect(ordered.map { $0.schema } == ["public", "sales"])
    }

    @Test("One table listed twice is emitted once")
    func repeatedTableIsEmittedOnce() {
        let ordered = ForeignKeyTopologicalSort.ordered(
            [table("orders", "public"), table("orders", "public")],
            foreignKeysByTable: [:]
        )

        #expect(ordered.map { $0.identifier } == ["public.orders"])
    }

    @Test("A parent precedes every child that references it")
    func parentPrecedesChild() {
        let ordered = ForeignKeyTopologicalSort.ordered(
            [table("orders", "public"), table("customers", "public")],
            foreignKeysByTable: ["public.orders": [foreignKey(to: "customers", schema: "public")]]
        )

        #expect(ordered.map { $0.identifier } == ["public.customers", "public.orders"])
    }

    @Test("A foreign key that names no schema points inside the referencing table's schema")
    func unqualifiedForeignKeyResolvesInsideTheReferencingSchema() {
        let ordered = ForeignKeyTopologicalSort.ordered(
            [table("invoices", "sales"), table("regions", "sales")],
            foreignKeysByTable: ["sales.invoices": [foreignKey(to: "regions")]]
        )

        #expect(ordered.map { $0.identifier } == ["sales.regions", "sales.invoices"])
    }

    @Test("A foreign key across schemas orders the table it really points at")
    func crossSchemaForeignKeyOrdersTheReferencedSchema() {
        let ordered = ForeignKeyTopologicalSort.ordered(
            [table("orders", "sales"), table("customers", "public"), table("customers", "sales")],
            foreignKeysByTable: [
                "sales.orders": [foreignKey(to: "customers", schema: "public")],
                "sales.customers": [foreignKey(to: "orders", schema: "sales")]
            ]
        )

        #expect(ordered.map { $0.identifier } == ["public.customers", "sales.orders", "sales.customers"])
    }

    @Test("childrenFirst puts a child ahead of its parent")
    func childrenFirstReversesDependencyOrder() {
        let ordered = ForeignKeyTopologicalSort.ordered(
            [table("orders", "public"), table("customers", "public")],
            foreignKeysByTable: ["public.orders": [foreignKey(to: "customers", schema: "public")]],
            childrenFirst: true
        )

        #expect(ordered.map { $0.identifier } == ["public.orders", "public.customers"])
    }

    @Test("A dependency cycle keeps every table exactly once")
    func cycleKeepsEveryTableExactlyOnce() {
        let ordered = ForeignKeyTopologicalSort.ordered(
            [table("orders", "public"), table("customers", "public"), table("orders", "sales")],
            foreignKeysByTable: [
                "public.orders": [foreignKey(to: "customers", schema: "public")],
                "public.customers": [foreignKey(to: "orders", schema: "public")]
            ]
        )
        let identifiers = ordered.map { $0.identifier }

        #expect(identifiers.count == 3)
        #expect(Set(identifiers) == ["public.orders", "public.customers", "sales.orders"])
    }

    @Test("A cycle names its own members, in the order they were given")
    func cycleNamesItsMembersInInputOrder() {
        let ordering = ForeignKeyTopologicalSort.order(
            [table("orders", "public"), table("regions", "public"), table("customers", "public")],
            foreignKeysByTable: [
                "public.orders": [foreignKey(to: "customers", schema: "public")],
                "public.customers": [foreignKey(to: "orders", schema: "public")]
            ]
        )

        #expect(ordering.unorderedByCycle.map { $0.identifier } == ["public.orders", "public.customers"])
        #expect(Set(ordering.tables.map { $0.identifier })
            == ["public.orders", "public.customers", "public.regions"])
    }

    @Test("A table that only descends from a cycle is ordered after it, not reported inside it")
    func descendantOfACycleIsOrderedAfterIt() {
        let ordering = ForeignKeyTopologicalSort.order(
            [table("audit", "public"), table("orders", "public"), table("customers", "public")],
            foreignKeysByTable: [
                "public.orders": [foreignKey(to: "customers", schema: "public")],
                "public.customers": [foreignKey(to: "orders", schema: "public")],
                "public.audit": [foreignKey(to: "orders", schema: "public")]
            ]
        )
        let identifiers = ordering.tables.map { $0.identifier }

        #expect(ordering.unorderedByCycle.map { $0.identifier } == ["public.orders", "public.customers"])
        #expect(identifiers.last == "public.audit")
        #expect(identifiers.count == 3)
    }

    @Test("An acyclic graph strands nothing")
    func acyclicGraphStrandsNothing() {
        let ordering = ForeignKeyTopologicalSort.order(
            [table("orders", "public"), table("customers", "public")],
            foreignKeysByTable: ["public.orders": [foreignKey(to: "customers", schema: "public")]]
        )

        #expect(ordering.unorderedByCycle.isEmpty)
        #expect(ordering.tables.map { $0.identifier } == ["public.customers", "public.orders"])
    }

    @Test("A self-referencing foreign key does not strand its table")
    func selfReferenceDoesNotStrandTheTable() {
        let ordered = ForeignKeyTopologicalSort.ordered(
            [table("employees", "public"), table("departments", "public")],
            foreignKeysByTable: ["public.employees": [foreignKey(to: "employees", schema: "public")]]
        )

        #expect(ordered.map { $0.identifier } == ["public.departments", "public.employees"])
    }
}
