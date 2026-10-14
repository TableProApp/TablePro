//
//  MySQLIndexKeyHandoffWriterTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// The indexes TableProTests' MySQLIndexKeyHandoffTests holds the structure editor to handing over after a rename,
// a key edit and a typed expression.
struct MySQLIndexKeyHandoffWriterTests {
    private func index(
        _ name: String,
        columns: [String],
        expressions: [String]? = nil,
        spelling: String? = nil
    ) -> PluginIndexDefinition {
        PluginIndexDefinition(
            name: name,
            columns: columns,
            indexType: "BTREE",
            expressions: expressions,
            includedColumns: nil,
            ddlMethodAndKeys: spelling,
            ddlWhereClause: nil
        )
    }

    @Test("Renaming a descending functional index recreates it descending")
    func renameKeepsFunctionalDescending() {
        let renamed = index(
            "i_fn_lower", columns: ["lower(`v`)"], expressions: ["lower(`v`)"],
            spelling: "((lower(`v`)) DESC) USING BTREE"
        )
        #expect(
            mysqlModifyIndexSQL(table: "t", oldIndexName: "i_fn", newIndex: renamed, flavor: .mysql)
                == "ALTER TABLE `t` DROP INDEX `i_fn`, ADD INDEX `i_fn_lower` ((lower(`v`)) DESC) USING BTREE"
        )
    }

    @Test("Renaming a descending column index recreates it descending")
    func renameKeepsColumnDescending() {
        let renamed = index("i_v_desc", columns: ["v", "id"], spelling: "(`v` DESC, `id`) USING BTREE")
        #expect(
            mysqlModifyIndexSQL(table: "t", oldIndexName: "i_desc", newIndex: renamed, flavor: .mysql)
                == "ALTER TABLE `t` DROP INDEX `i_desc`, ADD INDEX `i_v_desc` (`v` DESC, `id`) USING BTREE"
        )
    }

    @Test("A key edited away from its spelling is written from the fields")
    func keyEditWritesFromTheFields() {
        let edited = index("i_fn", columns: ["lower(`v`)", "id"], expressions: ["lower(`v`)"])
        #expect(mysqlIndexDefinitionSQL(edited) == "INDEX `i_fn` ((lower(`v`)), `id`) USING BTREE")
    }

    @Test("A typed expression reaches the statement as an expression")
    func typedExpressionIsWritten() {
        let typed = index("ix", columns: ["id", "coalesce(a, b)"], expressions: ["coalesce(a, b)"])
        #expect(mysqlIndexDefinitionSQL(typed) == "INDEX `ix` (`id`, (coalesce(a, b))) USING BTREE")
    }
}
