//
//  StructureChangeManagerIndexExpressionTests.swift
//  TableProTests
//
//  A PostgreSQL index over an expression, with INCLUDE columns and the server's own DDL spellings,
//  edited in the structure editor and written back.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Structure Change Manager expression indexes")
@MainActor
struct StructureChangeManagerIndexExpressionTests {
    private static let keys = "USING btree (tenant_id, lower(email)) INCLUDE (name)"

    private func loadedManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "users",
            columns: ["id", "tenant_id", "email", "name"].map {
                ColumnInfo(name: $0, dataType: "TEXT", isNullable: true, isPrimaryKey: $0 == "id")
            },
            indexes: [
                IndexInfo(
                    name: "users_tenant_lower_email",
                    columns: ["tenant_id", "lower(email)"],
                    isUnique: true,
                    isPrimary: false,
                    type: "BTREE",
                    expressions: ["lower(email)"],
                    includedColumns: ["name"],
                    ddlMethodAndKeys: Self.keys
                )
            ],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    private func stagedIndex(_ manager: StructureChangeManager) -> EditableIndexDefinition? {
        guard case .modifyIndex(_, let new)? = manager.getChangesArray().first else { return nil }
        return new
    }

    private func keys(_ manager: StructureChangeManager) -> IndexKeyContext {
        .testing(.postgresql, columns: manager.workingColumns.map(\.name))
    }

    @Test("Renaming an expression index raises no missing-column error and recreates it from its spelling")
    func renameKeepsTheExpression() throws {
        let manager = loadedManager()
        var renamed = manager.workingIndexes[0]
        renamed.name = "users_tenant_email"
        manager.updateIndex(id: renamed.id, with: renamed)

        #expect(manager.validationErrors.isEmpty)
        #expect(manager.canCommit)
        let new = try #require(stagedIndex(manager))
        let sql = PostgreSQLIndexClauses.createStatement(for: new.toPlugin(), qualifiedTable: #""public"."users""#)
        #expect(sql == #"CREATE UNIQUE INDEX "users_tenant_email" ON "public"."users" USING btree (tenant_id, lower(email)) INCLUDE (name)"#)
    }

    @Test("The same Columns text changes nothing, and a reordered one writes the expression from the fields")
    func reenteredColumnsKeepTheExpression() throws {
        let manager = loadedManager()
        var edited = manager.workingIndexes[0]
        StructureEditingSupport.updateIndex(&edited, at: 1, with: "tenant_id, lower(email)", keys: keys(manager))
        #expect(edited == manager.workingIndexes[0])

        StructureEditingSupport.updateIndex(&edited, at: 1, with: "lower(email), tenant_id", keys: keys(manager))
        manager.updateIndex(id: edited.id, with: edited)
        #expect(manager.validationErrors.isEmpty)
        let new = try #require(stagedIndex(manager))
        #expect(new.ddlMethodAndKeys == nil)
        let sql = PostgreSQLIndexClauses.createStatement(for: new.toPlugin(), qualifiedTable: #""public"."users""#)
        #expect(sql == #"CREATE UNIQUE INDEX "users_tenant_lower_email" ON "public"."users" USING btree ((lower(email)), "tenant_id") INCLUDE ("name")"#)
    }

    @Test("A new index typed with an expression validates and writes the expression in parentheses")
    func typedExpressionOnANewIndex() throws {
        let manager = loadedManager()
        manager.addNewIndex()
        var added = try #require(manager.workingIndexes.last)
        StructureEditingSupport.updateIndex(&added, at: 0, with: "ix", keys: keys(manager))
        StructureEditingSupport.updateIndex(&added, at: 1, with: "tenant_id, lower(email)", keys: keys(manager))
        manager.updateIndex(id: added.id, with: added)

        #expect(manager.validationErrors.isEmpty)
        #expect(manager.canCommit)
        guard case .addIndex(let staged)? = manager.getChangesArray().last else {
            Issue.record("Expected a staged index add")
            return
        }
        let sql = PostgreSQLIndexClauses.createStatement(for: staged.toPlugin(), qualifiedTable: #""public"."users""#)
        #expect(sql == #"CREATE INDEX "ix" ON "public"."users" USING btree ("tenant_id", (lower(email)))"#)
    }

    @Test("An expression typed with a sort order is refused before anything runs")
    func typedSortOrderIsRefused() throws {
        let manager = loadedManager()
        manager.addNewIndex()
        var added = try #require(manager.workingIndexes.last)
        StructureEditingSupport.updateIndex(&added, at: 0, with: "ix", keys: keys(manager))
        StructureEditingSupport.updateIndex(&added, at: 1, with: "lower(email) DESC", keys: keys(manager))
        manager.updateIndex(id: added.id, with: added)

        #expect(manager.validationErrors[.index(added.id)]
            == "Index references a column that does not exist: lower(email) DESC")
        #expect(!manager.canCommit)
    }

    @Test("An INCLUDE column the table does not have is reported")
    func missingIncludedColumnIsReported() {
        let manager = loadedManager()
        var edited = manager.workingIndexes[0]
        edited.includedColumns = ["nickname"]
        manager.updateIndex(id: edited.id, with: edited)

        #expect(manager.validationErrors[.index(edited.id)] == "Index references a column that does not exist: nickname")
        #expect(!manager.canCommit)
    }
}
