//
//  MySQLIndexKeyWriterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct MySQLIndexKeyWriterTests {
    private func catalogRow(
        _ index: String,
        column: String?,
        expression: String? = nil,
        collation: String? = "A"
    ) -> MySQLIndexRow? {
        MySQLIndexRow(
            table: "t",
            index: index,
            column: column,
            catalogExpression: expression,
            prefixLength: nil,
            collation: collation,
            isNonUnique: true,
            type: "BTREE"
        )
    }

    private func read(_ rows: [MySQLIndexRow?], named name: String) throws -> EditableIndexDefinition {
        let indexes = MySQLIndexGrouping.group(rows.compactMap { $0 })["t"] ?? []
        let info = try #require(indexes.first { $0.name == name })
        return EditableIndexDefinition.from(IndexInfo(info))
    }

    @Test("Expression keys are written in parentheses beside quoted and prefixed columns")
    func expressionKeysAreParenthesized() {
        let index = PluginIndexDefinition(
            name: "ix",
            columns: ["id", "coalesce(a, b)", "email"],
            indexType: "BTREE",
            columnPrefixes: ["email": 20],
            expressions: ["coalesce(a, b)"],
            includedColumns: nil,
            ddlMethodAndKeys: nil,
            ddlWhereClause: nil
        )
        #expect(mysqlIndexDefinitionSQL(index) == "INDEX `ix` (`id`, (coalesce(a, b)), `email`(20)) USING BTREE")
    }

    @Test("Renaming a descending functional index recreates it descending")
    func renameKeepsFunctionalDescending() throws {
        var index = try read([catalogRow("i_fn", column: nil, expression: "lower(`v`)", collation: "D")], named: "i_fn")
        index.name = "i_fn_lower"

        #expect(
            mysqlModifyIndexSQL(table: "t", oldIndexName: "i_fn", newIndex: index.toPlugin(), flavor: .mysql)
                == "ALTER TABLE `t` DROP INDEX `i_fn`, ADD INDEX `i_fn_lower` ((lower(`v`)) DESC) USING BTREE"
        )
    }

    @Test("Renaming a descending column index recreates it descending")
    func renameKeepsColumnDescending() throws {
        var index = try read(
            [catalogRow("i_desc", column: "v", collation: "D"), catalogRow("i_desc", column: "id")],
            named: "i_desc"
        )
        index.name = "i_v_desc"

        #expect(
            mysqlModifyIndexSQL(table: "t", oldIndexName: "i_desc", newIndex: index.toPlugin(), flavor: .mysql)
                == "ALTER TABLE `t` DROP INDEX `i_desc`, ADD INDEX `i_v_desc` (`v` DESC, `id`) USING BTREE"
        )
    }

    @Test("Changing the key of a descending index writes it from the fields")
    func keyEditWritesFromTheFields() throws {
        var index = try read([catalogRow("i_fn", column: nil, expression: "lower(`v`)", collation: "D")], named: "i_fn")
        StructureEditingSupport.updateIndex(
            &index, at: 1, with: "lower(`v`), id", keys: .testing(.mysql, columns: ["id", "v"])
        )

        #expect(index.expressions == ["lower(`v`)"])
        #expect(mysqlIndexDefinitionSQL(index.toPlugin()) == "INDEX `i_fn` ((lower(`v`)), `id`) USING BTREE")
    }

    @Test("A typed expression reaches the statement as an expression")
    func typedExpressionIsWritten() {
        var index = EditableIndexDefinition.placeholder()
        let keys = IndexKeyContext.testing(.mysql, columns: ["id", "a", "b"])
        StructureEditingSupport.updateIndex(&index, at: 0, with: "ix", keys: keys)
        StructureEditingSupport.updateIndex(&index, at: 1, with: "id, coalesce(a, b)", keys: keys)

        #expect(mysqlIndexDefinitionSQL(index.toPlugin()) == "INDEX `ix` (`id`, (coalesce(a, b))) USING BTREE")
    }

    @Test("Only MySQL and MariaDB replace an index in one ALTER TABLE")
    func oneStatementModifyByFlavor() {
        let index = PluginIndexDefinition(name: "ix", columns: ["a"], indexType: "BTREE")
        #expect(
            mysqlModifyIndexSQL(table: "t", oldIndexName: "ix", newIndex: index, flavor: .mariadb)
                == "ALTER TABLE `t` DROP INDEX `ix`, ADD INDEX `ix` (`a`) USING BTREE"
        )
        #expect(mysqlModifyIndexSQL(table: "t", oldIndexName: "ix", newIndex: index, flavor: .tidb(version: nil)) == nil)
        #expect(
            mysqlModifyIndexSQL(table: "t", oldIndexName: "ix", newIndex: index, flavor: .oceanbase(version: nil)) == nil
        )
        #expect(mysqlModifyIndexSQL(table: "t", oldIndexName: "ix", newIndex: index, flavor: .databend) == nil)
    }

    /// Measured on MariaDB 13.0.2: `ADD INDEX PRIMARY (b)`, `ADD INDEX primary (b)` and
    /// `ADD INDEX Primary (b)` each fail with ERROR 1280, "Incorrect index name".
    @Test("An added index named PRIMARY in any case is refused, and a name that only starts with it is not")
    func primaryIsNotAnIndexName() {
        for name in ["PRIMARY", "primary", "Primary"] {
            #expect(mysqlReservedIndexNameRefusal(for: PluginIndexDefinition(name: name, columns: ["id"])) != nil)
        }
        #expect(mysqlReservedIndexNameRefusal(for: PluginIndexDefinition(name: "primary_email", columns: ["email"])) == nil)
    }
}
