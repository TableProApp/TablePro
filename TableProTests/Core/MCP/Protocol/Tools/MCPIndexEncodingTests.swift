//
//  MCPIndexEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCP index encoding")
struct MCPIndexEncodingTests {
    @Test("Expressions and INCLUDE columns are listed when an index has them")
    func expressionsAndIncludedColumnsAreEncoded() {
        let encoded = MCPConnectionBridge.encode(index: IndexInfo(
            name: "users_tenant_lower_email",
            columns: ["tenant_id", "lower(email)"],
            isUnique: true,
            isPrimary: false,
            type: "BTREE",
            expressions: ["lower(email)"],
            includedColumns: ["name"],
            ddlMethodAndKeys: "USING btree (tenant_id, lower(email)) INCLUDE (name)"
        ))
        #expect(encoded["expressions"]?.arrayValue?.compactMap(\.stringValue) == ["lower(email)"])
        #expect(encoded["included_columns"]?.arrayValue?.compactMap(\.stringValue) == ["name"])
        #expect(encoded["ddl_method_and_keys"] == nil)
    }

    @Test("An index with no expressions or INCLUDE columns carries neither key")
    func plainIndexOmitsTheKeys() {
        let encoded = MCPConnectionBridge.encode(index: IndexInfo(
            name: "users_email", columns: ["email"], isUnique: false, isPrimary: false, type: "BTREE",
            expressions: [], includedColumns: []
        ))
        #expect(encoded["expressions"] == nil)
        #expect(encoded["included_columns"] == nil)
        #expect(encoded["columns"]?.arrayValue?.compactMap(\.stringValue) == ["email"])
    }

    @Test("An invalid index says so, and every other index reads as valid")
    func validityIsEncoded() {
        let invalid = MCPConnectionBridge.encode(index: IndexInfo(
            name: "users_email_key", columns: ["email"], isUnique: true, isPrimary: false, type: "BTREE",
            isValid: false
        ))
        let valid = MCPConnectionBridge.encode(index: IndexInfo(
            name: "users_email", columns: ["email"], isUnique: false, isPrimary: false, type: "BTREE"
        ))
        #expect(invalid["is_valid"] == .bool(false))
        #expect(valid["is_valid"] == .bool(true))
    }

    @Test("The published index schema declares is_valid as a required boolean")
    func schemaDeclaresValidity() {
        let properties = MCPToolSchema.indexDefinition["properties"]
        #expect(properties?["is_valid"]?["type"] == .string("boolean"))
        #expect(MCPToolSchema.indexDefinition["required"]?.arrayValue?.contains(.string("is_valid")) == true)
    }
}
