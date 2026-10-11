//
//  IndexDefinitionPasteTests.swift
//  TableProTests
//
//  An index copied from one table's Indexes tab and pasted into another's, on the same engine or on
//  a different one.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct IndexDefinitionPasteTests {
    private static func copiedFromPostgreSQL() throws -> EditableIndexDefinition {
        let read = EditableIndexDefinition.from(IndexInfo(
            name: "users_tenant_lower_email",
            columns: ["tenant_id", "lower(email)"],
            isUnique: true,
            isPrimary: false,
            type: "btree",
            expressions: ["lower(email)"],
            includedColumns: ["name"],
            ddlMethodAndKeys: "USING btree (tenant_id, lower(email)) INCLUDE (name)"
        ))
        let clipboard = try JSONEncoder().encode([read])
        let decoded = try JSONDecoder().decode([EditableIndexDefinition].self, from: clipboard)
        return try #require(decoded.first)
    }

    private func managerWithUsersTable() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "users",
            columns: ["id", "tenant_id", "email", "name"].map {
                ColumnInfo(name: $0, dataType: "TEXT", isNullable: true, isPrimaryKey: $0 == "id")
            },
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    @Test("Within one engine the expressions and INCLUDE columns arrive, under a new identity")
    func sameEngineKeepsEverything() throws {
        let copied = try Self.copiedFromPostgreSQL()
        let pasted = copied.pasted(from: .postgresql, into: .postgresql)

        #expect(pasted.id != copied.id)
        #expect(pasted.columns == ["tenant_id", "lower(email)"])
        #expect(pasted.expressions == ["lower(email)"])
        #expect(pasted.includedColumns == ["name"])
    }

    @Test("Within one engine family the fields arrive, as they do in Copy To")
    func sameFamilyKeepsEverything() throws {
        let pasted = try Self.copiedFromPostgreSQL().pasted(from: .postgresql, into: .cockroachdb)

        #expect(pasted.expressions == ["lower(email)"])
        #expect(pasted.includedColumns == ["name"])
    }

    @Test("Across engines an expression stays a plain entry and INCLUDE columns are left behind")
    func crossEngineDropsSourceSQL() throws {
        let pasted = try Self.copiedFromPostgreSQL().pasted(from: .postgresql, into: .mysql)

        #expect(pasted.columns == ["tenant_id", "lower(email)"])
        #expect(pasted.expressions.isEmpty)
        #expect(pasted.includedColumns.isEmpty)
        #expect(pasted.ddlMethodAndKeys == nil)
    }

    @Test("A copy whose source is not recorded is treated as coming from another engine")
    func unknownSourceDropsSourceSQL() throws {
        let pasted = try Self.copiedFromPostgreSQL().pasted(from: nil, into: .postgresql)

        #expect(pasted.expressions.isEmpty)
        #expect(pasted.includedColumns.isEmpty)
    }

    @Test("An expression index pasted into another engine's table is reported before anything runs")
    func crossEnginePasteIsReportedInline() throws {
        let manager = managerWithUsersTable()
        let pasted = try Self.copiedFromPostgreSQL().pasted(from: .postgresql, into: .mysql)
        manager.addIndex(pasted)

        #expect(
            manager.validationErrors[.index(pasted.id)]
                == "Index references a column that does not exist: lower(email)"
        )
        #expect(!manager.canCommit)
    }

    @Test("The same index pasted within PostgreSQL passes the column check")
    func sameEnginePasteIsValid() throws {
        let manager = managerWithUsersTable()
        let pasted = try Self.copiedFromPostgreSQL().pasted(from: .postgresql, into: .postgresql)
        manager.addIndex(pasted)

        #expect(manager.validationErrors.isEmpty)
    }
}
