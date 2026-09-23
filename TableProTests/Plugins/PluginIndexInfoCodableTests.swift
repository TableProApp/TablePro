//
//  PluginIndexInfoCodableTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PluginIndexInfo and PluginIndexDefinition index fields")
struct PluginIndexInfoCodableTests {
    @Test("A payload written before the new fields existed decodes with none of them")
    func legacyPayloadDecodesToNil() throws {
        let legacyJson = Data("""
        {
            "name": "orders_email",
            "columns": ["email"],
            "isUnique": true,
            "isPrimary": false,
            "type": "BTREE"
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PluginIndexInfo.self, from: legacyJson)
        #expect(decoded.name == "orders_email")
        #expect(decoded.expressions == nil)
        #expect(decoded.includedColumns == nil)
        #expect(decoded.ddlMethodAndKeys == nil)
        #expect(decoded.ddlWhereClause == nil)
        #expect(decoded.isValid == nil)
    }

    @Test("The published initializer leaves the new fields nil")
    func publishedInitializerLeavesNewFieldsNil() {
        let info = PluginIndexInfo(name: "ix", columns: ["a"], isUnique: true, type: "HASH", whereClause: "(a > 0)")
        #expect(info.expressions == nil)
        #expect(info.includedColumns == nil)
        #expect(info.ddlMethodAndKeys == nil)
        #expect(info.ddlWhereClause == nil)
        #expect(info.isValid == nil)
        #expect(info.whereClause == "(a > 0)")

        let spelled = PluginIndexInfo(
            name: "ix", columns: ["a"], expressions: nil, includedColumns: nil,
            ddlMethodAndKeys: "USING btree (a)", ddlWhereClause: nil
        )
        #expect(spelled.ddlMethodAndKeys == "USING btree (a)")
        #expect(spelled.isValid == nil)

        let definition = PluginIndexDefinition(name: "ix", columns: ["a"], indexType: "HASH")
        #expect(definition.expressions == nil)
        #expect(definition.includedColumns == nil)
        #expect(definition.ddlMethodAndKeys == nil)
        #expect(definition.ddlWhereClause == nil)
    }

    @Test("The full initializer stores the new fields and they round-trip through JSON")
    func fullInitializerRoundTrips() throws {
        let original = PluginIndexInfo(
            name: "users_tenant_lower_email",
            columns: ["tenant_id", "lower(email)"],
            isUnique: true,
            whereClause: "(m = 'a'::mood)",
            expressions: ["lower(email)"],
            includedColumns: ["name"],
            ddlMethodAndKeys: "USING btree (tenant_id, lower(email)) INCLUDE (name)",
            ddlWhereClause: "(m = 'a'::src.mood)",
            isValid: false
        )
        let decoded = try JSONDecoder().decode(PluginIndexInfo.self, from: JSONEncoder().encode(original))
        #expect(decoded.isValid == false)
        #expect(decoded.expressions == ["lower(email)"])
        #expect(decoded.includedColumns == ["name"])
        #expect(decoded.ddlMethodAndKeys == "USING btree (tenant_id, lower(email)) INCLUDE (name)")
        #expect(decoded.ddlWhereClause == "(m = 'a'::src.mood)")

        let definition = PluginIndexDefinition(
            name: "ix",
            columns: ["lower(email)"],
            expressions: ["lower(email)"],
            includedColumns: ["name"],
            ddlMethodAndKeys: "USING btree (lower(email)) INCLUDE (name)",
            ddlWhereClause: "(a > 0)"
        )
        #expect(definition.expressions == ["lower(email)"])
        #expect(definition.includedColumns == ["name"])
        #expect(definition.ddlMethodAndKeys == "USING btree (lower(email)) INCLUDE (name)")
        #expect(definition.ddlWhereClause == "(a > 0)")
    }
}
