//
//  MySQLIndexKeyHandoffTests.swift
//  TableProTests
//
//  A MySQL index read from the catalog, edited in the structure editor and handed back to the driver.
//  The indexes below are what the MySQL plugin's MySQLIndexGrouping reads for a descending functional
//  key and a descending column key; MySQLDriverTests holds the plugin to writing the statement from
//  the spelling when the key is unchanged and from the fields when it is not.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct MySQLIndexKeyHandoffTests {
    private static let functionalDescending = PluginIndexInfo(
        name: "i_fn", columns: ["lower(`v`)"], expressions: ["lower(`v`)"], includedColumns: nil,
        ddlMethodAndKeys: "((lower(`v`)) DESC) USING BTREE", ddlWhereClause: nil
    )

    private static let columnDescending = PluginIndexInfo(
        name: "i_desc", columns: ["v", "id"], expressions: nil, includedColumns: nil,
        ddlMethodAndKeys: "(`v` DESC, `id`) USING BTREE", ddlWhereClause: nil
    )

    private func read(_ info: PluginIndexInfo) -> EditableIndexDefinition {
        EditableIndexDefinition.from(IndexInfo(info))
    }

    @Test("Renaming a descending functional index hands over its own spelling")
    func renameKeepsFunctionalDescending() {
        var index = read(Self.functionalDescending)
        index.name = "i_fn_lower"

        let written = index.toPlugin()
        #expect(written.name == "i_fn_lower")
        #expect(written.ddlMethodAndKeys == "((lower(`v`)) DESC) USING BTREE")
    }

    @Test("Renaming a descending column index hands over its own spelling")
    func renameKeepsColumnDescending() {
        var index = read(Self.columnDescending)
        index.name = "i_v_desc"

        let written = index.toPlugin()
        #expect(written.name == "i_v_desc")
        #expect(written.ddlMethodAndKeys == "(`v` DESC, `id`) USING BTREE")
    }

    @Test("Changing the key of a descending index hands over the fields and no spelling")
    func keyEditWritesFromTheFields() {
        var index = read(Self.functionalDescending)
        StructureEditingSupport.updateIndex(
            &index, at: 1, with: "lower(`v`), id", keys: .testing(.mysql, columns: ["id", "v"])
        )

        #expect(index.expressions == ["lower(`v`)"])
        let written = index.toPlugin()
        #expect(written.ddlMethodAndKeys == nil)
        #expect(written.columns == ["lower(`v`)", "id"])
        #expect(written.expressions == ["lower(`v`)"])
        #expect(written.indexType?.uppercased() == "BTREE")
    }

    @Test("A typed expression reaches the driver as an expression")
    func typedExpressionIsWritten() {
        var index = EditableIndexDefinition.placeholder()
        let keys = IndexKeyContext.testing(.mysql, columns: ["id", "a", "b"])
        StructureEditingSupport.updateIndex(&index, at: 0, with: "ix", keys: keys)
        StructureEditingSupport.updateIndex(&index, at: 1, with: "id, coalesce(a, b)", keys: keys)

        let written = index.toPlugin()
        #expect(written.name == "ix")
        #expect(written.columns == ["id", "coalesce(a, b)"])
        #expect(written.expressions == ["coalesce(a, b)"])
        #expect(written.ddlMethodAndKeys == nil)
    }
}
