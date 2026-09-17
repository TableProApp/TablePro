//
//  ForeignKeyDefinitionGroupingTests.swift
//  TableProTests
//
//  Foreign key rows, one per column, grouped into one editable definition per constraint.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Editable Foreign Key Definition grouping")
struct ForeignKeyDefinitionGroupingTests {
    private static let rows = [
        ForeignKeyInfo(
            name: "fk_b", column: "b2", referencedTable: "parent_b", referencedColumn: "pb2",
            referencedSchema: "ref", onDelete: "cascade", onUpdate: "set null"
        ),
        ForeignKeyInfo(
            name: "fk_a", column: "a1", referencedTable: "parent_a", referencedColumn: "pa1",
            onDelete: "bogus", onUpdate: "Set Default"
        ),
        ForeignKeyInfo(
            name: "fk_b", column: "b1", referencedTable: "ignored", referencedColumn: "pb1",
            referencedSchema: "ignored", onDelete: "RESTRICT", onUpdate: "RESTRICT"
        )
    ]

    @Test("Constraints keep the order their first row was read in")
    func constraintsKeepFirstSeenOrder() {
        let keys = EditableForeignKeyDefinition.grouping(Self.rows)
        #expect(keys.map(\.name) == ["fk_b", "fk_a"])
    }

    @Test("A constraint's columns keep the order of its rows")
    func columnsKeepRowOrder() throws {
        let composite = try #require(EditableForeignKeyDefinition.grouping(Self.rows).first)
        #expect(composite.columns == ["b2", "b1"])
        #expect(composite.referencedColumns == ["pb2", "pb1"])
    }

    @Test("Identity, referenced table, schema and actions come from a constraint's first row")
    func constraintReadsItsFirstRow() throws {
        let composite = try #require(EditableForeignKeyDefinition.grouping(Self.rows).first)
        #expect(composite.id == Self.rows[0].id)
        #expect(composite.referencedTable == "parent_b")
        #expect(composite.referencedSchema == "ref")
        #expect(composite.onDelete == .cascade)
        #expect(composite.onUpdate == .setNull)
    }

    @Test("Actions are read regardless of case, and an unknown one reads as NO ACTION")
    func actionsParseLikeASingleRow() throws {
        let single = try #require(EditableForeignKeyDefinition.grouping(Self.rows).last)
        #expect(single.onDelete == .noAction)
        #expect(single.onUpdate == .setDefault)
        #expect(single.columns == ["a1"])
    }

    @Test("No rows give no constraints")
    func noRowsGiveNoConstraints() {
        #expect(EditableForeignKeyDefinition.grouping([]).isEmpty)
    }
}
