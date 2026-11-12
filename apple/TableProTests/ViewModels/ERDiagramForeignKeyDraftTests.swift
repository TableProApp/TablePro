//
//  ERDiagramForeignKeyDraftTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ERDiagramForeignKeyDraftTests {
    private typealias Pair = ERDiagramForeignKeyDraft.ColumnPair

    private func draft(_ pairs: [(String, String)]) -> ERDiagramForeignKeyDraft {
        ERDiagramForeignKeyDraft(
            table: "line_items",
            pairs: pairs.map { Pair(column: $0.0, referencedColumn: $0.1) },
            referencedTable: "orders",
            name: "fk_line_items_tenant_id"
        )
    }

    @Test("The pairs map to the key's two column lists in pair order")
    func pairOrderMapsToTheKey() {
        var composite = draft([("tenant_id", "tenant_id"), ("order_id", "id")])
        composite.onDelete = .cascade

        let key = composite.foreignKey

        #expect(key.columns == ["tenant_id", "order_id"])
        #expect(key.referencedColumns == ["tenant_id", "id"])
        #expect(key.referencedTable == "orders")
        #expect(key.name == "fk_line_items_tenant_id")
        #expect(key.onDelete == .cascade)
    }

    @Test("A drop on a member of a two-column key offers the whole key, the dragged pair in its place")
    func dropOnACompositeMemberOffersTheWholeKey() {
        let started = ERDiagramForeignKeyDraft.starting(
            table: "line_items",
            column: "order_id",
            referencedTable: "orders",
            keyColumns: ["tenant_id", "id"],
            target: "id",
            sourceColumns: ["id", "Tenant_ID", "order_id"],
            name: "fk_line_items_order_id"
        )

        #expect(started.pairs.map { $0.referencedColumn } == ["tenant_id", "id"])
        #expect(started.pairs.map { $0.column } == ["Tenant_ID", "order_id"])
        #expect(started.issue == nil)
    }

    @Test("A drop on a column outside the key keeps that one pair")
    func dropOutsideTheKeyIsOnePair() {
        let started = ERDiagramForeignKeyDraft.starting(
            table: "line_items",
            column: "order_code",
            referencedTable: "orders",
            keyColumns: ["tenant_id", "id"],
            target: "code",
            sourceColumns: ["order_code"],
            name: "fk"
        )

        #expect(started.pairs.map { $0.column } == ["order_code"])
        #expect(started.pairs.map { $0.referencedColumn } == ["code"])
    }

    @Test("Choosing another referenced table rebuilds its side from that table's key and keeps the chosen column")
    func referencingRebuildsFromTheKey() {
        let single = draft([("order_id", "id")])
        let sources = ["id", "tenant_id", "order_id"]

        let composite = single.referencing("shipments", keyColumns: ["tenant_id", "id"], sourceColumns: sources)

        #expect(composite.referencedTable == "shipments")
        #expect(composite.pairs.map { $0.column } == ["tenant_id", "order_id"])
        #expect(composite.pairs.map { $0.referencedColumn } == ["tenant_id", "id"])
    }

    @Test("A table's own id is never taken for the referenced id")
    func ownIdIsNotAGuess() {
        let single = draft([("order_id", "id")])
            .referencing("orders", keyColumns: ["id"], sourceColumns: ["id", "order_id"])

        #expect(single.pairs.map { $0.column } == ["order_id"])
    }

    @Test("A column with no namesake stays blank, and the draft says a row is incomplete")
    func unguessedColumnIsBlank() {
        let composite = draft([("order_id", "id")])
            .referencing("shipments", keyColumns: ["id", "region"], sourceColumns: ["order_id"])

        #expect(composite.pairs.map { $0.column } == ["order_id", ""])
        #expect(composite.issue == .incompletePair)
    }

    @Test("A repeated column on either side is named")
    func repeatsAreNamed() {
        #expect(draft([("a", "x"), ("a", "y")]).issue == .repeatedColumn("a"))
        #expect(draft([("a", "x"), ("b", "x")]).issue == .repeatedReferencedColumn("x"))
        #expect(draft([("a", "x"), ("b", "y")]).issue == nil)
    }

    @Test("Each whole-value edit changes only the pair it names")
    func editsNameTheirPair() throws {
        let composite = draft([("a", "x"), ("b", "y")])
        let second = try #require(composite.pairs.last?.id)

        let edited = composite.settingColumn("c", of: second).settingReferencedColumn("z", of: second)

        #expect(edited.pairs.map { $0.column } == ["a", "c"])
        #expect(edited.pairs.map { $0.referencedColumn } == ["x", "z"])
    }

    @Test("Adding, moving and removing pairs keep the key's order, and the last pair stays")
    func addMoveRemove() throws {
        let composite = draft([("a", "x"), ("b", "y")]).addingPair()
        #expect(composite.pairs.count == 3)
        #expect(composite.issue == .incompletePair)

        let moved = composite.movingPairs(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(moved.pairs.map { $0.column } == ["b", "a", ""])

        let first = try #require(moved.pairs.first?.id)
        let blank = try #require(moved.pairs.last?.id)
        let trimmed = moved.removingPairs([first, blank])
        #expect(trimmed.pairs.map { $0.column } == ["a"])

        let everything = Set(trimmed.pairs.map { $0.id })
        #expect(trimmed.removingPairs(everything) == trimmed)
    }
}
