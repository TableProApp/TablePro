//
//  StructureEditingSupportIndexKeyTests.swift
//  TableProTests
//
//  The Indexes tab's Columns cell parsed back into key parts.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Structure editing index key parts")
@MainActor
struct StructureEditingSupportIndexKeyTests {
    private func index(columns: [String], expressions: [String] = []) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: "ix", columns: columns, type: .btree, isUnique: false, isPrimary: false,
            comment: nil, expressions: expressions
        )
    }

    @Test("A comma inside parentheses or quotes stays in its entry")
    func nestedCommasStayInTheirEntry() {
        #expect(StructureEditingSupport.indexKeyParts("tenant_id, coalesce(a, b)") == ["tenant_id", "coalesce(a, b)"])
        #expect(StructureEditingSupport.indexKeyParts("(a || ', ' || b), c") == ["(a || ', ' || b)", "c"])
        #expect(StructureEditingSupport.indexKeyParts(#""d,e", f"#) == [#""d,e""#, "f"])
    }

    @Test("Empty entries are dropped the way a plain split dropped them")
    func emptyEntriesAreDropped() {
        #expect(StructureEditingSupport.indexKeyParts("").isEmpty)
        #expect(StructureEditingSupport.indexKeyParts("a,,b") == ["a", "b"])
    }

    @Test("An expression keeps its commas and stays an expression across the edit")
    func expressionSurvivesTheEdit() {
        var edited = index(columns: ["tenant_id", "coalesce(a, b)"], expressions: ["coalesce(a, b)"])
        StructureEditingSupport.updateIndex(&edited, at: 1, with: "tenant_id, coalesce(a, b), created")
        #expect(edited.columns == ["tenant_id", "coalesce(a, b)", "created"])
        #expect(edited.expressions == ["coalesce(a, b)"])
        #expect(edited.columnPrefixes.isEmpty)
    }

    @Test("An expression removed from the cell leaves the expression list")
    func removedExpressionLeavesTheList() {
        var edited = index(columns: ["tenant_id", "lower(email)"], expressions: ["lower(email)"])
        StructureEditingSupport.updateIndex(&edited, at: 1, with: "tenant_id")
        #expect(edited.columns == ["tenant_id"])
        #expect(edited.expressions.isEmpty)
    }

    @Test("A MySQL key prefix is still read as a prefix")
    func mysqlPrefixIsStillAPrefix() {
        var edited = index(columns: ["email"])
        StructureEditingSupport.updateIndex(&edited, at: 1, with: "email(20), name")
        #expect(edited.columns == ["email", "name"])
        #expect(edited.columnPrefixes == ["email": 20])
        #expect(edited.expressions.isEmpty)
    }

    @Test("An expression that looks like a prefix is not read as one")
    func expressionShapedLikeAPrefix() {
        var edited = index(columns: ["f(20)"], expressions: ["f(20)"])
        StructureEditingSupport.updateIndex(&edited, at: 1, with: "f(20)")
        #expect(edited.columns == ["f(20)"])
        #expect(edited.columnPrefixes.isEmpty)
        #expect(edited.expressions == ["f(20)"])
    }
}
