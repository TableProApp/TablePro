//
//  RoutineAndTriggerToolSchemaTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// The declared output schema is the contract an MCP client reads. A field the bridge emits but the
/// schema never declares is a silent disagreement: the tool answers with keys the client was told
/// would not be there. `list_routines` shipped exactly that, emitting `return_type` and `language`
/// against a schema that declared neither.
@Suite("Routine and trigger tool schemas")
struct RoutineAndTriggerToolSchemaTests {
    private func itemProperties(_ schema: JsonValue?, array: String) throws -> Set<String> {
        let output = try #require(schema)
        let items = try #require(output["properties"]?[array]?["items"])
        let properties = try #require(items["properties"]?.objectValue)
        return Set(properties.keys)
    }

    @Test("list_routines declares every field the bridge emits")
    func routineOutputSchemaIsComplete() throws {
        let declared = try itemProperties(ListRoutinesTool.outputSchema, array: "routines")
        #expect(declared.isSuperset(of: [
            "name", "kind", "schema", "qualified_name", "signature", "return_type", "language"
        ]))
    }

    @Test("list_routines requires only a connection")
    func routineInputRequiresConnectionOnly() throws {
        let required = ListRoutinesTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["connection_id"])
    }

    /// A schema-wide answer spans many tables, so the table cannot stay a required top-level field.
    @Test("list_triggers takes an optional table and never requires it")
    func triggerInputTableIsOptional() throws {
        let schema = ListTriggersTool.inputSchema
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id"])
        #expect(schema["properties"]?["table"] != nil)
    }

    @Test("list_triggers declares every field the bridge emits")
    func triggerOutputSchemaIsComplete() throws {
        let declared = try itemProperties(ListTriggersTool.outputSchema, array: "triggers")
        #expect(declared.isSuperset(of: [
            "name", "table", "schema", "timing", "event", "orientation", "statement",
            "definition", "is_enabled"
        ]))
    }

    /// Only the four the driver always fills may be required; the rest depend on the engine.
    /// `MCPToolSchema.object` sorts the required list, so compare as a set.
    @Test("list_triggers requires only what every engine reports")
    func triggerOutputRequiresOnlyUniversalFields() throws {
        let output = try #require(ListTriggersTool.outputSchema)
        let items = try #require(output["properties"]?["triggers"]?["items"])
        let required = Set(items["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(required == ["name", "timing", "event", "statement"])
        #expect(output["required"]?.arrayValue?.compactMap(\.stringValue) == ["triggers"])
    }
}
