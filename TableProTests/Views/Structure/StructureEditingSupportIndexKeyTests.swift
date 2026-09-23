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
    private static let columns = ["owner's_id", "created_at", "tenant_id", "a", "b", "c", "email", "name", "created"]

    private func index(columns: [String], expressions: [String] = []) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: "ix", columns: columns, type: .btree, isUnique: false, isPrimary: false,
            comment: nil, expressions: expressions
        )
    }

    private func edit(
        _ index: inout EditableIndexDefinition,
        to text: String,
        on databaseType: DatabaseType = .postgresql
    ) {
        StructureEditingSupport.updateIndex(
            &index, at: 1, with: text, keys: .testing(databaseType, columns: Self.columns)
        )
    }

    @Test("Adding a column to an index over a name with an apostrophe keeps every column")
    func apostropheColumnSurvivesTheEdit() {
        var edited = index(columns: ["owner's_id", "created_at"])
        edit(&edited, to: "owner's_id, created_at, tenant_id", on: .mysql)
        #expect(edited.columns == ["owner's_id", "created_at", "tenant_id"])
        #expect(edited.expressions.isEmpty)
        #expect(edited.columnPrefixes.isEmpty)
    }

    @Test("An expression keeps its commas and stays an expression across the edit")
    func expressionSurvivesTheEdit() {
        var edited = index(columns: ["tenant_id", "coalesce(a, b)"], expressions: ["coalesce(a, b)"])
        edit(&edited, to: "tenant_id, coalesce(a, b), created")
        #expect(edited.columns == ["tenant_id", "coalesce(a, b)", "created"])
        #expect(edited.expressions == ["coalesce(a, b)"])
        #expect(edited.columnPrefixes.isEmpty)
    }

    @Test("An expression typed into the cell is an expression, commas and all")
    func typedExpressionIsAnExpression() {
        var edited = index(columns: ["tenant_id"])
        edit(&edited, to: "tenant_id, coalesce(a, c)")
        #expect(edited.columns == ["tenant_id", "coalesce(a, c)"])
        #expect(edited.expressions == ["coalesce(a, c)"])
    }

    @Test("An expression edited by hand replaces the one the index had")
    func editedExpressionReplacesTheOld() {
        var edited = index(columns: ["coalesce(a, b)"], expressions: ["coalesce(a, b)"])
        edit(&edited, to: "coalesce(a, c)")
        #expect(edited.columns == ["coalesce(a, c)"])
        #expect(edited.expressions == ["coalesce(a, c)"])
    }

    @Test("An expression removed from the cell leaves the expression list")
    func removedExpressionLeavesTheList() {
        var edited = index(columns: ["tenant_id", "lower(email)"], expressions: ["lower(email)"])
        edit(&edited, to: "tenant_id")
        #expect(edited.columns == ["tenant_id"])
        #expect(edited.expressions.isEmpty)
    }

    @Test("A MySQL key prefix is still read as a prefix")
    func mysqlPrefixIsStillAPrefix() {
        var edited = index(columns: ["email"])
        edit(&edited, to: "email(20), name", on: .mysql)
        #expect(edited.columns == ["email", "name"])
        #expect(edited.columnPrefixes == ["email": 20])
        #expect(edited.expressions.isEmpty)
    }

    @Test("An expression that looks like a prefix is not read as one")
    func expressionShapedLikeAPrefix() {
        var edited = index(columns: ["f(20)"], expressions: ["f(20)"])
        edit(&edited, to: "f(20)", on: .mysql)
        #expect(edited.columns == ["f(20)"])
        #expect(edited.columnPrefixes.isEmpty)
        #expect(edited.expressions == ["f(20)"])
    }

    @Test("An engine without expression keys reads a call as a column name, which the column check names")
    func columnsOnlyEngineKeepsTheText() {
        var edited = index(columns: ["email"])
        edit(&edited, to: "lower(email)", on: .mssql)
        #expect(edited.columns == ["lower(email)"])
        #expect(edited.expressions.isEmpty)
        #expect(edited.referencedColumnNames == ["lower(email)"])
    }

    @Test("Only the Columns cell reads key parts")
    func otherCellsIgnoreTheKeyContext() {
        var edited = index(columns: ["email"])
        StructureEditingSupport.updateIndex(&edited, at: 0, with: "ix_email", keys: .testing(.postgresql))
        StructureEditingSupport.updateIndex(&edited, at: 4, with: "email IS NOT NULL", keys: .testing(.postgresql))
        #expect(edited.name == "ix_email")
        #expect(edited.whereClause == "email IS NOT NULL")
        #expect(edited.columns == ["email"])
    }
}
