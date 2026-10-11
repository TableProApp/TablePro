//
//  TableStructureSnapshotKeyTests.swift
//  TableProTests
//
//  The index and foreign key read Copy To, Duplicate Table and Compare build their DDL from.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableStructureSnapshotKeyTests {
    private func snapshot(
        indexes: [PluginIndexInfo] = [],
        foreignKeys: [PluginForeignKeyInfo] = []
    ) -> TableStructureSnapshot {
        TableStructureSnapshot.from(
            table: PluginTableInfo(name: "child", schema: "app", comment: nil),
            columns: [],
            indexes: indexes,
            foreignKeys: foreignKeys
        )
    }

    @Test("The rows of one key become one definition, in the order the driver reported the keys")
    func foreignKeyRowsGroupInDriverOrder() throws {
        let keys = snapshot(foreignKeys: [
            PluginForeignKeyInfo(
                name: "fk_b", column: "b2", referencedTable: "parent_b", referencedColumn: "pb2",
                referencedDatabase: nil, referencedSchema: "ref", onDelete: "cascade", onUpdate: "set null"
            ),
            PluginForeignKeyInfo(
                name: "fk_a", column: "a1", referencedTable: "parent_a", referencedColumn: "pa1",
                referencedDatabase: nil, onDelete: "bogus"
            ),
            PluginForeignKeyInfo(
                name: "fk_b", column: "b1", referencedTable: "ignored", referencedColumn: "pb1",
                referencedDatabase: nil, referencedSchema: "ignored", onDelete: "RESTRICT", onUpdate: "RESTRICT"
            )
        ]).foreignKeys

        #expect(keys.map(\.name) == ["fk_b", "fk_a"])
        let composite = try #require(keys.first)
        #expect(composite.columns == ["b2", "b1"])
        #expect(composite.referencedColumns == ["pb2", "pb1"])
        #expect(composite.referencedTable == "parent_b")
        #expect(composite.referencedSchema == "ref")
        #expect(composite.onDelete == .cascade)
        #expect(composite.onUpdate == .setNull)
        #expect(keys.last?.onDelete == .noAction)
    }

    @Test("An index read keeps its predicate, prefixes and flags")
    func indexKeepsPredicateAndPrefixes() throws {
        let indexes = snapshot(indexes: [
            PluginIndexInfo(
                name: "orders_active_email",
                columns: ["email", "tenant"],
                isUnique: true,
                isPrimary: false,
                type: "hash",
                columnPrefixes: ["email": 20],
                whereClause: "(active)"
            )
        ]).indexes

        let index = try #require(indexes.first)
        #expect(index.name == "orders_active_email")
        #expect(index.columns == ["email", "tenant"])
        #expect(index.isUnique)
        #expect(!index.isPrimary)
        #expect(index.type == .hash)
        #expect(index.columnPrefixes == ["email": 20])
        #expect(index.whereClause == "(active)")
    }
}
