//
//  MCPSchemaSearchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("search_schema reach")
@MainActor
struct MCPSchemaSearchTests {
    private struct ReadFailed: Error {}

    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

    private func table(_ name: String, _ schema: String, _ type: TableInfo.TableType = .table) -> TableInfo {
        TestFixtures.makeTableInfo(name: name, type: type, schema: schema)
    }

    private func request(
        _ term: String,
        limit: Int = 50,
        reach: MCPSchemaSearch.TableReach = .everySchema(excluding: ["pg_catalog"])
    ) -> MCPSchemaSearch.Request {
        MCPSchemaSearch.Request(scope: scope, term: term, limit: limit, tableReach: reach)
    }

    private func search(
        _ request: MCPSchemaSearch.Request,
        on driver: MockDatabaseDriver
    ) async throws -> MCPSchemaSearch.Result {
        try await MCPSchemaSearch.run(request, metadata: SchemaSearchMetadataProvider(driver: driver))
    }

    @Test("A search that names no schema finds a table in another schema")
    func findsATableInAnotherSchema() async throws {
        let driver = MockDatabaseDriver()
        driver.schemaTablesToReturn = ["public": [table("users", "public")]]
        driver.allSchemaTablesToReturn = [table("users", "public"), table("timesheet", "attendance")]

        let result = try await search(request("timesheet"), on: driver)

        #expect(result.matches == [.table(name: "timesheet", schema: "attendance", type: .table)])
        #expect(driver.fetchTablesInAllSchemasCallCount == 1)
        #expect(driver.fetchSchemaTablesCalls.isEmpty)
    }

    @Test("Views and other table-like objects in other schemas keep their kind")
    func viewsKeepTheirKind() async throws {
        let driver = MockDatabaseDriver()
        driver.allSchemaTablesToReturn = [
            table("timesheet_summary", "reporting", .view),
            table("timesheet_totals", "reporting", .materializedView)
        ]

        let result = try await search(request("timesheet"), on: driver)

        #expect(result.matches == [
            .table(name: "timesheet_summary", schema: "reporting", type: .view),
            .table(name: "timesheet_totals", schema: "reporting", type: .materializedView)
        ])
    }

    @Test("Naming a schema searches that schema alone")
    func namingASchemaNarrowsTheSearch() async throws {
        let driver = MockDatabaseDriver()
        driver.schemaTablesToReturn = ["public": [table("users", "public")]]
        driver.allSchemaTablesToReturn = [table("users", "public"), table("timesheet", "attendance")]

        let result = try await search(request("timesheet", reach: .scopeSchema), on: driver)

        #expect(result.matches.isEmpty)
        #expect(driver.fetchTablesInAllSchemasCallCount == 0)
        #expect(driver.fetchSchemaTablesCalls == ["public"])
    }

    @Test("Without a single call for every schema, each schema is listed through the one scope")
    func perSchemaFallbackUsesTheOwnerListing() async throws {
        let driver = MockDatabaseDriver()
        driver.schemasToReturn = ["public", "attendance", "pg_catalog"]
        driver.schemaTablesToReturn = [
            "public": [table("users", "public")],
            "attendance": [table("timesheet", "attendance")],
            "pg_catalog": [table("pg_timesheet", "pg_catalog")]
        ]
        let metadata = SchemaSearchMetadataProvider(driver: driver)

        let result = try await MCPSchemaSearch.run(request("timesheet"), metadata: metadata)

        #expect(result.matches == [.table(name: "timesheet", schema: "attendance", type: .table)])
        #expect(driver.fetchSchemaTablesCalls == ["public", "attendance"])
        #expect(Set(metadata.requestedScopes) == [scope])
    }

    @Test("A schema whose tables could not be listed is named in the result")
    func unlistedSchemaIsReported() async throws {
        let driver = MockDatabaseDriver()
        driver.schemasToReturn = ["public", "payroll", "attendance"]
        driver.schemaTablesToReturn = [
            "public": [table("users", "public")],
            "attendance": [table("timesheet", "attendance")]
        ]
        driver.schemaTablesErrors = ["payroll": ReadFailed()]

        let result = try await search(request("timesheet"), on: driver)

        #expect(result.matches == [.table(name: "timesheet", schema: "attendance", type: .table)])
        #expect(result.unlistedSchemas == ["payroll"])
    }

    @Test("Tables in the current schema lead, then the other schemas in name order")
    func currentSchemaLeads() async throws {
        let driver = MockDatabaseDriver()
        driver.allSchemaTablesToReturn = [
            table("users", "attendance"),
            table("users", "zeta"),
            table("user_roles", "public"),
            table("users", "public")
        ]

        let result = try await search(request("user"), on: driver)

        #expect(result.matches == [
            .table(name: "user_roles", schema: "public", type: .table),
            .table(name: "users", schema: "public", type: .table),
            .table(name: "users", schema: "attendance", type: .table),
            .table(name: "users", schema: "zeta", type: .table)
        ])
    }

    @Test("Columns come from the schema the driver is on, and each one names it")
    func columnsNameTheirSchema() async throws {
        let driver = MockDatabaseDriver()
        driver.currentSchema = "public"
        driver.allSchemaTablesToReturn = [table("users", "public"), table("timesheet", "attendance")]
        driver.allColumnsToReturn = ["users": [TestFixtures.makeColumnInfo(name: "email", dataType: "text")]]

        let result = try await search(request("email"), on: driver)

        #expect(result.matches == [.column(name: "email", table: "users", schema: "public", dataType: "text")])
        #expect(result.columnSearch == .searched(schema: "public"))
    }

    @Test("Table matches past the limit clip the result without reading columns")
    func tableMatchesPastTheLimit() async throws {
        let driver = MockDatabaseDriver()
        driver.allSchemaTablesToReturn = [table("log_a", "public"), table("log_b", "audit"), table("log_c", "audit")]
        driver.allColumnsToReturn = ["log_a": [TestFixtures.makeColumnInfo(name: "log_id")]]

        let result = try await search(request("log", limit: 2), on: driver)

        #expect(result.matches.count == 2)
        #expect(result.isTruncated)
        #expect(result.columnSearch == .limitReached)
        #expect(driver.fetchAllColumnsCallCount == 0)
    }

    @Test("Exactly as many matches as the limit is not a truncated result")
    func exactlyTheLimitIsNotTruncated() async throws {
        let driver = MockDatabaseDriver()
        driver.allSchemaTablesToReturn = [table("log_a", "public"), table("log_b", "audit")]

        let exact = try await search(request("log", limit: 2), on: driver)
        #expect(exact.matches.count == 2)
        #expect(!exact.isTruncated)
        #expect(exact.columnSearch == .searched(schema: "public"))

        driver.allColumnsToReturn = ["log_a": [TestFixtures.makeColumnInfo(name: "log_id")]]
        let over = try await search(request("log", limit: 2), on: driver)
        #expect(over.matches.count == 2)
        #expect(over.isTruncated)
    }

    @Test("A column read that fails keeps the table matches and says so")
    func failedColumnReadIsReported() async throws {
        let driver = MockDatabaseDriver()
        driver.allSchemaTablesToReturn = [table("timesheet", "attendance")]
        driver.fetchAllColumnsError = ReadFailed()

        let result = try await search(request("timesheet"), on: driver)

        #expect(result.matches == [.table(name: "timesheet", schema: "attendance", type: .table)])
        #expect(result.columnSearch == .failed)
        #expect(!result.isTruncated)
    }

    @Test("A lost connection fails the search rather than reading as no match")
    func lostConnectionFailsTheSearch() async {
        let driver = MockDatabaseDriver()
        driver.allSchemaTablesError = DatabaseError.notConnected

        await #expect(throws: DatabaseError.self) {
            try await search(request("timesheet"), on: driver)
        }
    }

    @Test("Only an unnamed schema on an engine that lists tables per schema reaches every schema")
    func reachFollowsTheEngineAndTheArguments() {
        let system: Set<String> = ["pg_catalog", "information_schema"]
        for grouping in [GroupingStrategy.bySchema, .hierarchicalSchema] {
            #expect(
                MCPSchemaSearch.tableReach(schemaIsNamed: false, grouping: grouping, systemSchemas: system)
                    == .everySchema(excluding: system)
            )
            #expect(
                MCPSchemaSearch.tableReach(schemaIsNamed: true, grouping: grouping, systemSchemas: system)
                    == .scopeSchema
            )
        }
        for grouping in [GroupingStrategy.flat, .byDatabase] {
            #expect(
                MCPSchemaSearch.tableReach(schemaIsNamed: false, grouping: grouping, systemSchemas: system)
                    == .scopeSchema
            )
        }
    }
}

@Suite("search_schema payload")
struct MCPSchemaSearchPayloadTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

    private func encode(_ result: MCPSchemaSearch.Result, schemaIsNamed: Bool = false) -> JsonValue {
        MCPConnectionBridge.encode(search: result, term: "time", scope: scope, schemaIsNamed: schemaIsNamed)
    }

    @Test("Every match carries its schema, null on an engine without schemas")
    func everyMatchCarriesItsSchema() throws {
        let payload = encode(MCPSchemaSearch.Result(
            matches: [
                .table(name: "timesheet", schema: "attendance", type: .view),
                .column(name: "started_at", table: "shifts", schema: "public", dataType: "timestamp"),
                .table(name: "clock", schema: nil, type: .table)
            ],
            isTruncated: false,
            unlistedSchemas: [],
            columnSearch: .searched(schema: "public")
        ))

        let matches = try #require(payload["matches"]?.arrayValue)
        #expect(matches.count == 3)
        #expect(matches[0]["schema"]?.stringValue == "attendance")
        #expect(matches[0]["object_type"]?.stringValue == "VIEW")
        #expect(matches[1]["schema"]?.stringValue == "public")
        #expect(matches[1]["table"]?.stringValue == "shifts")
        #expect(matches[2]["schema"]?.isNull == true)
    }

    @Test("An unnamed schema is echoed as null, a named one as itself")
    func schemaEcho() {
        let result = MCPSchemaSearch.Result(matches: [], isTruncated: false, unlistedSchemas: [], columnSearch: .failed)
        #expect(encode(result)["schema"]?.isNull == true)
        #expect(encode(result, schemaIsNamed: true)["schema"]?.stringValue == "public")
        #expect(encode(result)["database"]?.stringValue == "shop")
    }

    @Test("Unlisted schemas and the column outcome reach the caller")
    func partialCoverageIsReported() {
        let searched = encode(MCPSchemaSearch.Result(
            matches: [],
            isTruncated: false,
            unlistedSchemas: ["payroll"],
            columnSearch: .searched(schema: "public")
        ))
        #expect(searched["unlisted_schemas"]?.arrayValue?.compactMap(\.stringValue) == ["payroll"])
        #expect(searched["column_search"]?.stringValue == "searched")
        #expect(searched["columns_schema"]?.stringValue == "public")

        let clipped = encode(MCPSchemaSearch.Result(
            matches: [],
            isTruncated: true,
            unlistedSchemas: [],
            columnSearch: .limitReached
        ))
        #expect(clipped["unlisted_schemas"]?.arrayValue?.isEmpty == true)
        #expect(clipped["column_search"]?.stringValue == "limit_reached")
        #expect(clipped["columns_schema"] == nil)

        let failed = encode(MCPSchemaSearch.Result(matches: [], isTruncated: false, unlistedSchemas: [], columnSearch: .failed))
        #expect(failed["column_search"]?.stringValue == "failed")
        #expect(failed["columns_schema"] == nil)
    }

    @Test("The tool declares every schema-wide field it returns")
    func toolSchemaDeclaresThePayload() throws {
        let input = SearchSchemaTool.inputSchema
        #expect(input["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id", "term"])
        #expect(input["properties"]?["schema"]?["description"]?.stringValue?.contains("every schema") == true)

        let output = try #require(SearchSchemaTool.outputSchema)
        let required = output["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.contains("unlisted_schemas"))
        #expect(required.contains("column_search"))
        let columnSearch = output["properties"]?["column_search"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(columnSearch == ["searched", "limit_reached", "failed"])
        let item = try #require(output["properties"]?["matches"]?["items"])
        #expect(item["required"]?.arrayValue?.compactMap(\.stringValue).contains("schema") == true)
    }
}

@MainActor
private final class SchemaSearchMetadataProvider: ScopedMetadataProviding {
    private let driver: MockDatabaseDriver
    private(set) var requestedScopes: [DatabaseScope] = []

    init(driver: MockDatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedScopes.append(scope)
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}
