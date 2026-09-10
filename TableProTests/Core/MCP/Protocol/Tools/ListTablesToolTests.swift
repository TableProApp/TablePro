//
//  ListTablesToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ListTablesTool")
struct ListTablesToolTests {
    private let tool = ListTablesTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Tool exposes read-only metadata and declares include_row_counts")
    func metadata() throws {
        #expect(ListTablesTool.name == "list_tables")
        #expect(ListTablesTool.requiredScopes == [.toolsRead])
        #expect(ListTablesTool.annotations.readOnlyHint == true)
        let schema = ListTablesTool.inputSchema
        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id"])
        #expect(schema["properties"]?["include_row_counts"]?["type"]?.stringValue == "boolean")

        let output = try #require(ListTablesTool.outputSchema)
        #expect(output["properties"]?["row_counts_included"] != nil)
        #expect(output["properties"]?["row_counts_are_approximate"] != nil)
        let item = try #require(output["properties"]?["tables"]?["items"])
        #expect(item["properties"]?["row_count"]?["type"]?.stringValue == "integer")
    }

    @Test("Missing connection_id is a protocol error")
    func missingConnectionId() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([:]))
        }
    }

    @Test("A malformed connection id is a tool error the model can fix")
    func malformedConnectionId() async throws {
        let result = try await call(.object(["connection_id": .string("not-a-uuid")]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("A database passed as a number is an error, never silently ignored")
    func numericDatabaseIsRejected() async throws {
        do {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "database": .int(42)
            ]))
            Issue.record("Expected a numeric database to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
            #expect(error.message.contains("database"))
        }

        do {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "schema": .bool(true)
            ]))
            Issue.record("Expected a boolean schema to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
            #expect(error.message.contains("schema"))
        }
    }

    @Test("include_row_counts must be a boolean, not a string")
    func includeRowCountsMustBeABoolean() async throws {
        do {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "include_row_counts": .string("true")
            ]))
            Issue.record("Expected a string include_row_counts to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
            #expect(error.message.contains("include_row_counts"))
        }
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "include_counts": .bool(true)
            ]))
        }
    }

    @Test("A connection that is not open reports that, rather than an empty table list")
    func closedConnectionIsReported() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "include_row_counts": .bool(true)
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("not_connected:") == true)
    }
}

@Suite("ListTablesTool row counts")
struct ListTablesRowCountTests {
    private func table(
        name: String,
        rowCount: Int? = nil,
        schema: String? = "public",
        comment: String? = nil
    ) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: rowCount, schema: schema, comment: comment)
    }

    @Test("A fetched row count is carried into the encoded table")
    func rowCountIsEncoded() {
        let encoded = MCPConnectionBridge.encode(table: table(name: "users"), rowCount: 1_234)
        #expect(encoded["name"]?.stringValue == "users")
        #expect(encoded["row_count"]?.intValue == 1_234)
        #expect(encoded["schema"]?.stringValue == "public")
    }

    @Test("A missing row count is omitted rather than reported as zero")
    func missingRowCountIsOmitted() {
        let encoded = MCPConnectionBridge.encode(table: table(name: "users"), rowCount: nil)
        #expect(encoded["row_count"] == nil)
    }

    @Test("A zero row count is reported as zero, not dropped")
    func zeroRowCountIsReported() {
        let encoded = MCPConnectionBridge.encode(table: table(name: "empty"), rowCount: 0)
        #expect(encoded["row_count"]?.intValue == 0)
    }

    @Test("An empty schema or comment is omitted rather than sent blank")
    func blankMetadataIsOmitted() {
        let encoded = MCPConnectionBridge.encode(
            table: table(name: "users", schema: "", comment: ""),
            rowCount: nil
        )
        #expect(encoded["schema"] == nil)
        #expect(encoded["comment"] == nil)
    }

    @Test("Tables are ordered by schema, then name, then type")
    func tablesAreOrdered() {
        let ordered = MCPConnectionBridge.sortedTables([
            table(name: "zebra", schema: "public"),
            table(name: "alpha", schema: "public"),
            table(name: "alpha", schema: "audit")
        ])
        #expect(ordered.map(\.schema) == ["audit", "public", "public"])
        #expect(ordered.map(\.name) == ["alpha", "alpha", "zebra"])
    }

    @Test("Row counts are fetched one table at a time, so a wide schema skips them")
    func fanOutIsBounded() {
        #expect(MCPConnectionBridge.rowCountFanOutLimit == 200)
    }
}
