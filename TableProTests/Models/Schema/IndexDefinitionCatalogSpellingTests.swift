//
//  IndexDefinitionCatalogSpellingTests.swift
//  TableProTests
//
//  An index read with its key expressions, INCLUDE columns and the server's own DDL spellings, then
//  edited, encoded and handed back to a driver.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct IndexDefinitionCatalogSpellingTests {
    private static let keys = "USING btree (tenant_id, lower(email)) INCLUDE (name)"
    private static let predicate = "(m = 'a'::src.mood)"

    private static func loaded() -> EditableIndexDefinition {
        EditableIndexDefinition.from(IndexInfo(
            name: "users_tenant_lower_email",
            columns: ["tenant_id", "lower(email)"],
            isUnique: true,
            isPrimary: false,
            type: "btree",
            whereClause: "(m = 'a'::mood)",
            expressions: ["lower(email)"],
            includedColumns: ["name"],
            ddlMethodAndKeys: keys,
            ddlWhereClause: predicate
        ))
    }

    @Test("A read index carries its expressions, INCLUDE columns and both spellings")
    func readIndexCarriesEverything() {
        let index = Self.loaded()
        #expect(index.expressions == ["lower(email)"])
        #expect(index.includedColumns == ["name"])
        #expect(index.ddlMethodAndKeys == Self.keys)
        #expect(index.ddlWhereClause == Self.predicate)
    }

    @Test("A rename keeps both spellings")
    func renameKeepsBoth() {
        var index = Self.loaded()
        index.name = "users_tenant_email"
        index.isUnique = false
        #expect(index.ddlMethodAndKeys == Self.keys)
        #expect(index.ddlWhereClause == Self.predicate)
    }

    @Test("An edited condition retires its spelling and keeps the keys")
    func conditionEditKeepsKeys() {
        var index = Self.loaded()
        index.whereClause = "(m = 'b'::mood)"
        #expect(index.ddlWhereClause == nil)
        #expect(index.ddlMethodAndKeys == Self.keys)
    }

    @Test("An edit to the columns, the expressions, the INCLUDE list or the type retires the key spelling")
    func keyEditsRetireTheKeySpelling() {
        var columns = Self.loaded()
        columns.columns = ["tenant_id"]
        #expect(columns.ddlMethodAndKeys == nil)
        #expect(columns.ddlWhereClause == Self.predicate)

        var expressions = Self.loaded()
        expressions.expressions = []
        #expect(expressions.ddlMethodAndKeys == nil)

        var included = Self.loaded()
        included.includedColumns = []
        #expect(included.ddlMethodAndKeys == nil)

        var type = Self.loaded()
        type.type = .hash
        #expect(type.ddlMethodAndKeys == nil)
    }

    @Test("A changed key prefix retires the key spelling")
    func prefixEditRetiresTheKeySpelling() {
        let keys = "(`v` DESC, `email`(20)) USING BTREE"
        var index = EditableIndexDefinition.from(IndexInfo(
            name: "i_desc", columns: ["v", "email"], isUnique: false, isPrimary: false, type: "BTREE",
            columnPrefixes: ["email": 20], ddlMethodAndKeys: keys
        ))
        index.name = "i_desc_renamed"
        #expect(index.ddlMethodAndKeys == keys)

        index.columnPrefixes = ["email": 30]
        #expect(index.ddlMethodAndKeys == nil)
    }

    @Test("Changing a field and changing it back restores the spelling")
    func revertRestores() {
        var index = Self.loaded()
        index.type = .hash
        index.whereClause = nil
        index.type = .btree
        index.whereClause = "(m = 'a'::mood)"
        #expect(index.ddlMethodAndKeys == Self.keys)
        #expect(index.ddlWhereClause == Self.predicate)
        #expect(index == Self.loaded().withIdentity(of: index))
    }

    @Test("Dropping the spellings clears both")
    func dropClearsBoth() {
        var index = Self.loaded()
        index.dropCatalogSpellings()
        #expect(index.ddlMethodAndKeys == nil)
        #expect(index.ddlWhereClause == nil)
        #expect(index.expressions == ["lower(email)"])
    }

    @Test("A copy under a new identity keeps expressions and spellings")
    func newIdentityKeepsEverything() {
        let copy = Self.loaded().withNewIdentity()
        #expect(copy.expressions == ["lower(email)"])
        #expect(copy.includedColumns == ["name"])
        #expect(copy.ddlMethodAndKeys == Self.keys)
    }

    @Test("The spellings are not encoded, and the expressions and INCLUDE columns are")
    func encodingKeepsFieldsAndDropsSpellings() throws {
        let data = try JSONEncoder().encode(Self.loaded())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("src.mood"))
        #expect(!text.contains("USING btree"))

        let decoded = try JSONDecoder().decode(EditableIndexDefinition.self, from: data)
        #expect(decoded.expressions == ["lower(email)"])
        #expect(decoded.includedColumns == ["name"])
        #expect(decoded.ddlMethodAndKeys == nil)
        #expect(decoded.ddlWhereClause == nil)
        #expect(decoded.whereClause == "(m = 'a'::mood)")
    }

    @Test("An index copied before expressions existed still decodes")
    func legacyPayloadDecodes() throws {
        let legacyJson = Data("""
        {
            "id": "7C3B0D8E-9B7A-4A5C-8F2E-1D2C3B4A5968",
            "name": "idx_email",
            "columns": ["email"],
            "type": "BTREE",
            "isUnique": false,
            "isPrimary": false,
            "columnPrefixes": {}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(EditableIndexDefinition.self, from: legacyJson)
        #expect(decoded.name == "idx_email")
        #expect(decoded.expressions.isEmpty)
        #expect(decoded.includedColumns.isEmpty)
        #expect(decoded.whereClause == nil)
    }

    @Test("toPlugin and toIndexInfo carry the fields, and nil where a list is empty")
    func conversionsCarryTheFields() {
        let index = Self.loaded()
        let plugin = index.toPlugin()
        #expect(plugin.expressions == ["lower(email)"])
        #expect(plugin.includedColumns == ["name"])
        #expect(plugin.ddlMethodAndKeys == Self.keys)
        #expect(plugin.ddlWhereClause == Self.predicate)

        let info = index.toIndexInfo()
        #expect(info.expressions == ["lower(email)"])
        #expect(info.includedColumns == ["name"])
        #expect(info.ddlMethodAndKeys == Self.keys)
        #expect(info.ddlWhereClause == Self.predicate)

        let plain = EditableIndexDefinition.placeholder().toPlugin()
        #expect(plain.expressions == nil)
        #expect(plain.includedColumns == nil)
        #expect(plain.ddlMethodAndKeys == nil)
    }

    @Test("Only column names are referenced: key columns that are not expressions, then INCLUDE columns")
    func referencedColumnNames() {
        #expect(Self.loaded().referencedColumnNames == ["tenant_id", "name"])
    }
}

private extension EditableIndexDefinition {
    func withIdentity(of other: EditableIndexDefinition) -> EditableIndexDefinition {
        var copy = self
        copy.id = other.id
        return copy
    }
}
