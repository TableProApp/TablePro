//
//  MCPDataToolTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCPFilterArguments")
struct MCPFilterArgumentsTests {
    private func arguments(_ filters: [JsonValue]) -> JsonValue {
        .object(["filters": .array(filters)])
    }

    @Test("A filter is built from a column, an operator and a value")
    func filtersAreBuilt() throws {
        let filters = try MCPFilterArguments.filters(arguments([
            .object([
                "column": .string("email"),
                "operator": .string("CONTAINS"),
                "value": .string("@example.com")
            ])
        ]))
        #expect(filters.count == 1)
        #expect(filters.first?.columnName == "email")
        #expect(filters.first?.filterOperator == .contains)
        #expect(filters.first?.value == "@example.com")
        #expect(filters.first?.isEnabled == true)
    }

    @Test("The raw SQL escape hatch is not reachable over MCP")
    func rawSqlFiltersAreRefused() {
        #expect(throws: MCPToolExecutionError.self) {
            _ = try MCPFilterArguments.filters(arguments([
                .object([
                    "column": .string(TableFilter.rawSQLColumn),
                    "operator": .string("="),
                    "value": .string("1=1 OR 1=1")
                ])
            ]))
        }
    }

    @Test("An unknown operator is reported rather than passed through")
    func unknownOperatorIsReported() {
        #expect(throws: MCPToolExecutionError.self) {
            _ = try MCPFilterArguments.filters(arguments([
                .object([
                    "column": .string("id"),
                    "operator": .string("; DROP TABLE users --"),
                    "value": .string("1")
                ])
            ]))
        }
    }

    @Test("A filter missing its column or operator is a protocol error")
    func missingFilterFieldsAreProtocolErrors() {
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPFilterArguments.filters(arguments([.object(["operator": .string("=")])]))
        }
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPFilterArguments.filters(arguments([.object(["column": .string("id")])]))
        }
    }

    @Test("A filters value that is not an array of objects is a protocol error")
    func malformedFiltersAreProtocolErrors() {
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPFilterArguments.filters(.object(["filters": .string("id = 1")]))
        }
        #expect(throws: MCPProtocolError.self) {
            _ = try MCPFilterArguments.filters(.object(["filters": .array([.string("id = 1")])]))
        }
    }

    @Test("Operators that take no value do not need one")
    func valuelessOperators() throws {
        let filters = try MCPFilterArguments.filters(arguments([
            .object(["column": .string("deleted_at"), "operator": .string("IS NULL")])
        ]))
        #expect(filters.first?.filterOperator == .isNull)
    }

    @Test("Case sensitivity defaults to what the operator expects")
    func caseSensitivityDefaults() throws {
        let insensitive = try MCPFilterArguments.filters(arguments([
            .object(["column": .string("name"), "operator": .string("CONTAINS"), "value": .string("a")])
        ]))
        #expect(insensitive.first?.isCaseSensitive == false)

        let sensitive = try MCPFilterArguments.filters(arguments([
            .object(["column": .string("name"), "operator": .string("="), "value": .string("a")])
        ]))
        #expect(sensitive.first?.isCaseSensitive == true)

        let overridden = try MCPFilterArguments.filters(arguments([
            .object([
                "column": .string("name"),
                "operator": .string("CONTAINS"),
                "value": .string("a"),
                "case_sensitive": .bool(true)
            ])
        ]))
        #expect(overridden.first?.isCaseSensitive == true)
    }

    @Test("Sort entries default to ascending and reject an unknown direction")
    func sortDirections() throws {
        let sort = try MCPFilterArguments.sort(.object([
            "sort": .array([
                .object(["column": .string("id")]),
                .object(["column": .string("name"), "direction": .string("descending")])
            ])
        ]))
        #expect(sort.map(\.column) == ["id", "name"])
        #expect(sort.map(\.descending) == [false, true])

        #expect(throws: MCPToolExecutionError.self) {
            _ = try MCPFilterArguments.sort(.object([
                "sort": .array([.object(["column": .string("id"), "direction": .string("sideways")])])
            ]))
        }
    }

    @Test("Logic mode defaults to and and rejects anything else")
    func logicModes() throws {
        #expect(try MCPFilterArguments.logicMode(.object([:])) == .and)
        #expect(try MCPFilterArguments.logicMode(.object(["logic": .string("or")])) == .or)
        #expect(throws: MCPToolExecutionError.self) {
            _ = try MCPFilterArguments.logicMode(.object(["logic": .string("xor")]))
        }
    }
}

@Suite("CountRowsTool")
struct CountRowsToolTests {
    private let tool = CountRowsTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Counting rows is read-only and names the table it counted")
    func metadata() throws {
        #expect(CountRowsTool.name == "count_rows")
        #expect(CountRowsTool.requiredScopes == [.toolsRead])
        #expect(CountRowsTool.annotations.readOnlyHint == true)
        let output = try #require(CountRowsTool.outputSchema)
        #expect(output["properties"]?["is_approximate"] != nil)
        #expect(output["properties"]?["row_count"] != nil)
    }

    @Test("A raw SQL filter is refused before any connection work happens")
    func rawSqlFiltersAreRefusedEarly() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "table": .string("users"),
            "filters": .array([
                .object([
                    "column": .string(TableFilter.rawSQLColumn),
                    "operator": .string("="),
                    "value": .string("1=1")
                ])
            ])
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("An exact flag passed as a string is a protocol error")
    func exactMustBeABoolean() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "table": .string("users"),
                "exact": .string("yes")
            ]))
        }
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "table": .string("users"),
                "limit": .int(10)
            ]))
        }
    }
}

@Suite("InsertRowsTool")
struct InsertRowsToolTests {
    private let tool = InsertRowsTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Inserting rows is a write and takes bound values, never SQL text")
    func metadata() {
        #expect(InsertRowsTool.name == "insert_rows")
        #expect(InsertRowsTool.requiredScopes == [.toolsWrite])
        #expect(InsertRowsTool.annotations.readOnlyHint == false)
        let required = InsertRowsTool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue)
        #expect(required == ["columns", "connection_id", "rows", "table"])
        let properties = InsertRowsTool.inputSchema["properties"]?.objectValue ?? [:]
        #expect(properties["query"] == nil)
        #expect(properties["sql"] == nil)
    }

    @Test("An empty column list or row list is reported")
    func emptyInputsAreReported() async throws {
        let noColumns = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "table": .string("users"),
            "columns": .array([]),
            "rows": .array([.array([.int(1)])])
        ]))
        #expect(noColumns.isError)

        let noRows = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "table": .string("users"),
            "columns": .array([.string("id")]),
            "rows": .array([])
        ]))
        #expect(noRows.isError)
    }

    @Test("A row whose width does not match the columns is reported")
    func mismatchedRowWidthIsReported() async throws {
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "table": .string("users"),
            "columns": .array([.string("id"), .string("name")]),
            "rows": .array([.array([.int(1)])])
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("More rows than the per-call cap are reported rather than truncated")
    func tooManyRowsAreReported() async throws {
        let rows = (0...InsertRowsTool.maximumRows).map { JsonValue.array([.int($0)]) }
        let result = try await call(.object([
            "connection_id": .string(UUID().uuidString),
            "table": .string("users"),
            "columns": .array([.string("id")]),
            "rows": .array(rows)
        ]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.contains("1000") == true)
    }

    @Test("An unknown parameter is rejected")
    func unknownParameterIsRejected() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "table": .string("users"),
                "columns": .array([.string("id")]),
                "rows": .array([.array([.int(1)])]),
                "on_conflict": .string("ignore")
            ]))
        }
    }
}

@Suite("QuoteIdentifiersTool")
struct QuoteIdentifiersToolTests {
    private let tool = QuoteIdentifiersTool()

    private func call(_ arguments: JsonValue) async throws -> MCPToolCallResult {
        try await tool.call(
            arguments: arguments,
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services()
        )
    }

    @Test("Quoting is read-only and returns both lists in the order supplied")
    func metadata() throws {
        #expect(QuoteIdentifiersTool.name == "quote_identifiers")
        #expect(QuoteIdentifiersTool.requiredScopes == [.toolsRead])
        let output = try #require(QuoteIdentifiersTool.outputSchema)
        #expect(output["required"]?.arrayValue?.compactMap(\.stringValue) == ["identifiers", "literals"])
    }

    @Test("Asking for nothing is reported rather than answered with an empty result")
    func emptyRequestIsReported() async throws {
        let result = try await call(.object(["connection_id": .string(UUID().uuidString)]))
        #expect(result.isError)
        #expect(MCPToolTestHarness.errorText(result)?.hasPrefix("invalid_argument:") == true)
    }

    @Test("Identifiers must be strings")
    func identifiersMustBeStrings() async throws {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await call(.object([
                "connection_id": .string(UUID().uuidString),
                "identifiers": .array([.int(1)])
            ]))
        }
    }
}
