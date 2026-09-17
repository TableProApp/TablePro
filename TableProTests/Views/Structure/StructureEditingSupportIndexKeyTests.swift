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

    @Test("An expression from the index is taken whole, commas and quotes included")
    func expressionIsTakenWhole() {
        #expect(
            StructureEditingSupport.indexKeyParts("tenant_id, coalesce(a, b)", expressions: ["coalesce(a, b)"])
                == ["tenant_id", "coalesce(a, b)"]
        )
        #expect(
            StructureEditingSupport.indexKeyParts("(a || ', ' || b), c", expressions: ["(a || ', ' || b)"])
                == ["(a || ', ' || b)", "c"]
        )
        #expect(
            StructureEditingSupport.indexKeyParts("  lower(email)  ,  b ", expressions: ["lower(email)"])
                == ["lower(email)", "b"]
        )
    }

    @Test("A column name holding a quote or a parenthesis is split at every comma")
    func columnNamesAreSplitAtEveryComma() {
        #expect(
            StructureEditingSupport.indexKeyParts("owner's_id, created_at", expressions: [])
                == ["owner's_id", "created_at"]
        )
        #expect(StructureEditingSupport.indexKeyParts(#"size"in, id"#, expressions: []) == [#"size"in"#, "id"])
        #expect(
            StructureEditingSupport.indexKeyParts("O'Brien, lower(email)", expressions: ["lower(email)"])
                == ["O'Brien", "lower(email)"]
        )
    }

    @Test("Text that only begins with an expression, or edits one, is read as column names")
    func textThatIsNotTheExpressionIsColumnNames() {
        #expect(
            StructureEditingSupport.indexKeyParts("lower(email)x, b", expressions: ["lower(email)"])
                == ["lower(email)x", "b"]
        )
        #expect(
            StructureEditingSupport.indexKeyParts("coalesce(a, c)", expressions: ["coalesce(a, b)"])
                == ["coalesce(a", "c)"]
        )
    }

    @Test("Empty entries are dropped")
    func emptyEntriesAreDropped() {
        #expect(StructureEditingSupport.indexKeyParts("", expressions: []).isEmpty)
        #expect(StructureEditingSupport.indexKeyParts("a,,b", expressions: []) == ["a", "b"])
        #expect(StructureEditingSupport.indexKeyParts("a, ,b,", expressions: []) == ["a", "b"])
    }

    @Test("Adding a column to an index over a name with an apostrophe keeps every column")
    func apostropheColumnSurvivesTheEdit() {
        var edited = index(columns: ["owner's_id", "created_at"])
        StructureEditingSupport.updateIndex(&edited, at: 1, with: "owner's_id, created_at, tenant_id")
        #expect(edited.columns == ["owner's_id", "created_at", "tenant_id"])
        #expect(edited.expressions.isEmpty)
        #expect(edited.columnPrefixes.isEmpty)
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
