//
//  UserDefinedTypeToolSchemaTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("list_types tool schema")
struct UserDefinedTypeToolSchemaTests {
    @Test("list_types declares every field the bridge emits")
    func outputSchemaIsComplete() throws {
        let output = try #require(ListUserDefinedTypesTool.outputSchema)
        let items = try #require(output["properties"]?["types"]?["items"])
        let properties = try #require(items["properties"]?.objectValue)
        #expect(Set(properties.keys).isSuperset(of: [
            "name", "kind", "schema", "qualified_name", "labels", "fields", "base_type", "definition"
        ]))
        let required = Set(items["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(required == ["name", "kind", "qualified_name"])
    }

    @Test("list_types requires only a connection and restricts kind to the named kinds")
    func inputSchema() throws {
        let schema = ListUserDefinedTypesTool.inputSchema
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id"])
        let kinds = schema["properties"]?["kind"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(kinds == ["enum", "composite", "domain", "range"])
    }

    @Test("list_types is registered as a read-only tool")
    func registered() {
        #expect(MCPToolRegistry.tool(named: ListUserDefinedTypesTool.name) != nil)
        #expect(ListUserDefinedTypesTool.annotations.readOnlyHint == true)
        #expect(ListUserDefinedTypesTool.requiredScopes == [.toolsRead])
    }
}
