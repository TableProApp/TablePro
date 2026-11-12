//
//  MaskingBridgeTests.swift
//  TableProTests
//
//  MCP tools, the AI chat tools, AppleScript and Shortcuts all read rows through DatabaseAccessBridge.
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

@Suite(.serialized)
@MainActor
struct MaskingBridgeTests {
    nonisolated private static func customers() -> QueryResult {
        ScriptAnsweringDriver.resultSet(
            columns: ["id", "email"],
            rows: [["1", "jane@example.com"], ["2", "john@example.com"]]
        )
    }

    // What a driver that traces its columns reports for `SELECT id, email FROM customers`.
    nonisolated private static func tracedCustomers() -> QueryResult {
        traced(customers(), origins: [("customers", "id"), ("customers", "email")])
    }

    nonisolated private static func traced(_ result: QueryResult, origins: [(String, String)?]) -> QueryResult {
        var copy = result
        copy.columnOrigins = origins.map { origin in
            origin.map { PluginColumnOrigin(schema: "shop", table: $0.0, column: $0.1) }
        }
        return copy
    }

    private func install(type: DatabaseType = .mysql, sendsBatchesWhole: Bool = true) -> (ScriptAnsweringDriver, DatabaseScope) {
        var connection = TestFixtures.makeConnection(database: "shop", type: type)
        connection.maskingRules = [MaskingRule(pattern: "*.email")]
        let driver = ScriptAnsweringDriver(
            connection: connection,
            sendsBatchesWhole: sendsBatchesWhole,
            answer: { _ in ScriptAnsweringDriver.batch([Self.tracedCustomers(), Self.tracedCustomers()]) },
            statementAnswer: { _ in Self.tracedCustomers() }
        )
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (driver, DatabaseScope(connectionId: connection.id, database: "shop", schema: nil))
    }

    private static func leaks(_ result: QueryResult) -> Bool {
        result.rows.flatMap { $0 }.contains { $0.asText?.contains("@example.com") == true }
    }

    @Test("A statement read for MCP, the assistant or a script comes back masked")
    func statementIsMasked() async throws {
        let (driver, scope) = install()
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: scope, query: "SELECT id, email FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(!Self.leaks(outcome.result))
        #expect(outcome.result.rows.map { $0[0] } == [.text("1"), .text("2")])
    }

    @Test("Every result set of a script comes back masked")
    func scriptIsMasked() async throws {
        let (driver, scope) = install(type: .mssql)
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let outcome = try await DatabaseAccessBridge().runScript(
            scope: scope,
            query: "SELECT * FROM customers\nGO\nSELECT * FROM customers",
            maxRows: 10,
            timeoutSeconds: 30,
            cancellation: nil
        )

        #expect(!outcome.resultSets.isEmpty)
        #expect(!outcome.resultSets.contains(where: Self.leaks))
        #expect(!Self.leaks(outcome.primary))
    }

    @Test("What an MCP client receives as JSON holds no masked value")
    func mcpPayloadIsMasked() async throws {
        let (driver, scope) = install()
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let payload = try await MCPConnectionBridge().executeQuery(
            scope: scope, query: "SELECT id, email FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        let json = payload.jsonString(prettyPrinted: false)
        #expect(!json.contains("@example.com"))
        #expect(json.contains("••••"))
    }

    @Test("A table.column rule matches by table when the caller names the table")
    func maskingTableNarrowsTheMatch() async throws {
        var connection = TestFixtures.makeConnection(database: "shop")
        connection.maskingRules = [MaskingRule(pattern: "users.email")]
        let driver = ScriptAnsweringDriver(connection: connection, statementAnswer: { _ in Self.customers() })
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        let bridge = DatabaseAccessBridge()

        let other = try await bridge.runStatement(
            scope: scope, query: "SELECT * FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil,
            masking: .table("customers")
        )
        let unnamed = try await bridge.runStatement(
            scope: scope, query: "SELECT * FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(Self.leaks(other.result))
        #expect(!Self.leaks(unnamed.result))
    }

    private func install(
        type: DatabaseType = .mysql,
        answering answer: @escaping @Sendable (String) -> QueryResult
    ) -> (ScriptAnsweringDriver, DatabaseScope) {
        var connection = TestFixtures.makeConnection(database: "shop", type: type)
        connection.maskingRules = [MaskingRule(pattern: "*.email")]
        let driver = ScriptAnsweringDriver(connection: connection, statementAnswer: answer)
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (driver, DatabaseScope(connectionId: connection.id, database: "shop", schema: nil))
    }

    @Test("A column renamed with an alias is masked by the column it reads")
    func aliasIsMaskedByItsOrigin() async throws {
        let renamed = Self.traced(
            ScriptAnsweringDriver.resultSet(columns: ["id", "e"], rows: [["1", "jane@example.com"]]),
            origins: [("customers", "id"), ("customers", "email")]
        )
        let (driver, scope) = install { _ in renamed }
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: scope, query: "SELECT id, email AS e FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        #expect(!Self.leaks(outcome.result))
        #expect(outcome.result.rows.map { $0[0] } == [.text("1")])
    }

    @Test("A computed column whose origin nobody reports is masked whole")
    func expressionIsMasked() async throws {
        let computed = ScriptAnsweringDriver.resultSet(columns: ["lower(email)"], rows: [["jane@example.com"]])
        let (driver, scope) = install { _ in computed }
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let payload = try await MCPConnectionBridge().executeQuery(
            scope: scope, query: "SELECT lower(email) FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        let json = payload.jsonString(prettyPrinted: false)
        #expect(!json.contains("@example.com"))
        #expect(json.contains("lower(email)"))
        #expect(payload["status_message"] != nil)
    }

    @Test("A browse of one table stays readable where the rules say so")
    func browsedTableIsMatchedByName() async throws {
        let (driver, scope) = install { _ in Self.customers() }
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let outcome = try await DatabaseAccessBridge().runStatement(
            scope: scope, query: "SELECT id, email FROM customers", maxRows: 10, timeoutSeconds: 30, cancellation: nil,
            masking: .table("customers")
        )

        #expect(!Self.leaks(outcome.result))
        #expect(outcome.result.rows.map { $0[0] } == [.text("1"), .text("2")])
    }

    // Measured on MariaDB: `EXPLAIN FORMAT=JSON` wrote `a.email = 'alice@example.com'` read from a const table.
    @Test("A MySQL plan comes back masked on a connection with rules, a PostgreSQL plan readable")
    func planMaskingFollowsItsFormat() async throws {
        let cases: [(DatabaseType, ExplainVariant, Bool)] = [
            (.mysql, ExplainVariant(id: "json", label: "JSON", sqlPrefix: "EXPLAIN FORMAT=JSON", format: .mysqlComposite), false),
            (.postgresql, ExplainVariant(id: "json", label: "JSON", sqlPrefix: "EXPLAIN (FORMAT JSON)", format: .postgresJson), true),
        ]
        for (type, variant, readable) in cases {
            let plan = ScriptAnsweringDriver.resultSet(columns: ["EXPLAIN"], rows: [["a.email = 'jane@example.com'"]])
            let (driver, scope) = install(type: type) { _ in plan }
            defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
            let request = try MCPConnectionBridge.explainRequest(
                for: "SELECT * FROM users u JOIN a ON a.email = u.email WHERE u.id = 1",
                databaseType: type, variants: [variant], variantId: nil, analyze: false
            )
            let operation = try await ApprovedOperationFixture.approve(
                [OperationStatement(sql: request.statement)], scope: scope, databaseType: type
            )

            let payload = try await MCPConnectionBridge().explainQuery(
                operation, request: request, timeoutSeconds: 30, cancellation: nil
            )

            #expect(payload.jsonString(prettyPrinted: false).contains("@example.com") == readable, "\(type.rawValue)")
        }
    }

    @Test("A plan format nobody measured is masked as rows are")
    func unmeasuredPlanFormatsAreMaskedAsRows() {
        #expect(ExternalRowMasking.plan(in: .postgresJson) == .byName)
        #expect(ExternalRowMasking.plan(in: .sqliteQueryPlan) == .byName)
        #expect(ExternalRowMasking.plan(in: .mysqlComposite) == .byOrigin)
        #expect(ExternalRowMasking.plan(in: .indentedText) == .byOrigin)
        #expect(ExternalRowMasking.plan(in: nil) == .byOrigin)
    }

    // Measured on PostgreSQL 17: `SELECT id FROM users WHERE email::int = 0` fails quoting the address it read.
    @Test("A server error reaches an external caller as its code alone on a connection with rules")
    func serverErrorTextIsWithheld() async throws {
        for masked in [true, false] {
            var connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
            if masked { connection.maskingRules = [MaskingRule(pattern: "*.ssn")] }
            var session = ConnectionSession(
                connection: connection,
                driver: PluginDriverAdapter(connection: connection, pluginDriver: EchoingDriver())
            )
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: connection.id)
            defer { DatabaseManager.shared.removeSession(for: connection.id) }
            let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)

            var message: String?
            do {
                _ = try await DatabaseAccessBridge().runStatement(
                    scope: scope, query: "SELECT id FROM users WHERE email::int = 0", maxRows: 10, timeoutSeconds: 30,
                    cancellation: nil
                )
            } catch let refusal as DatabaseAccessError {
                message = refusal.message
            } catch let failure as any PluginDriverError {
                message = failure.pluginErrorMessage
            }

            let text = try #require(message)
            #expect(text.contains("jane@example.com") == !masked)
            #expect(text.contains("SQLSTATE 22P02") == masked)
        }
    }

    @Test("The app's own refusals keep their text")
    func ownErrorsKeepTheirText() {
        #expect(!ServerErrorText.mayRepeatAValue(DatabaseAccessError.timeout("Query timed out after 30 seconds")))
        #expect(!ServerErrorText.mayRepeatAValue(CancellationError()))
        #expect(!ServerErrorText.mayRepeatAValue(DatabaseError.notConnected))
        #expect(ServerErrorText.mayRepeatAValue(DatabaseError.queryFailed("Key (email)=(jane@example.com) already exists.")))
        #expect(ServerErrorText.mayRepeatAValue(EchoingServerError()))
        #expect(!ServerErrorText.mayRepeatAValue(DataWriteError.tooManyRowsAffected(table: "users", expected: 1, actual: 2)))
        #expect(ServerErrorText.mayRepeatAValue(
            DataWriteError.changeRefused(table: "users", kind: nil, reason: "The row could not be looked up: jane@example.com")
        ))
    }

    @Test("A refusal before any driver took the statement keeps its words; a driver's error does not")
    func refusalBeforeTheDriverKeepsItsText() async throws {
        let (driver, scope) = install()
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let refusal = DatabaseError.queryFailed("This tab is on shop. Switch the connection to that database to run it.")
        let bridge = DatabaseAccessBridge()

        let unreached = await bridge.externalError(refusal, on: scope.connectionId, reach: DriverReach())
        let reach = DriverReach()
        reach.mark()
        let reached = await bridge.externalError(refusal, on: scope.connectionId, reach: reach)

        #expect((unreached as? DatabaseError)?.errorDescription == refusal.errorDescription)
        #expect(reached is DatabaseAccessError)
    }

    @Test("History handed to MCP holds no error text from a connection with rules")
    func historyErrorTextIsWithheld() {
        let entry = QueryHistoryEntry(
            query: "UPDATE users SET name = NULL WHERE id = 1",
            connectionId: UUID(),
            databaseName: "shop",
            databaseType: .postgresql,
            source: .rowEdit,
            executionTime: 0,
            rowCount: 0,
            wasSuccessful: false,
            errorMessage: "null value in column \"name\" violates not-null constraint\nDETAIL: Failing row contains (1, jane@example.com, null)."
        )

        let withheld = MCPConnectionBridge.encode(historyEntry: entry, masksValues: true)
        let kept = MCPConnectionBridge.encode(historyEntry: entry)

        #expect(withheld["error_message"]?.stringValue == ServerErrorText.withheldMessage)
        #expect(kept["error_message"]?.stringValue?.contains("jane@example.com") == true)
    }

    // Edit Document writes `replaceOne(<every original field>, <every edited field>)` as the row edit's statement.
    @Test("History handed to MCP holds no statement the app wrote from stored values, on a connection with rules")
    func historyAppWrittenStatementsAreWithheld() {
        func entry(_ source: QueryHistorySource) -> QueryHistoryEntry {
            QueryHistoryEntry(
                query: #"db.users.replaceOne({"_id": 1, "email": "jane@example.com"}, {"_id": 1, "email": "jane@example.com", "name": "J"})"#,
                connectionId: UUID(),
                databaseName: "shop",
                databaseType: .mongodb,
                source: source,
                executionTime: 0,
                rowCount: 1,
                wasSuccessful: true
            )
        }

        for source in [QueryHistorySource.rowEdit, .dataImport] {
            #expect(
                MCPConnectionBridge.encode(historyEntry: entry(source), masksValues: true)["query"]?.stringValue
                    == ServerErrorText.withheldStatementText
            )
            #expect(MCPConnectionBridge.encode(historyEntry: entry(source))["query"]?.stringValue?.contains("jane@") == true)
        }
        #expect(MCPConnectionBridge.encode(historyEntry: entry(.editor), masksValues: true)["query"]?.stringValue?.contains("jane@") == true)

        // A search that matched the withheld text would answer for it one prefix at a time.
        #expect(!MCPConnectionBridge.isSearchable(entry(.rowEdit), by: "jan", masksValues: true))
        #expect(!MCPConnectionBridge.isSearchable(entry(.dataImport), by: "jan", masksValues: true))
        #expect(MCPConnectionBridge.isSearchable(entry(.rowEdit), by: nil, masksValues: true))
        #expect(MCPConnectionBridge.isSearchable(entry(.rowEdit), by: "", masksValues: true))
        #expect(MCPConnectionBridge.isSearchable(entry(.rowEdit), by: "jan", masksValues: false))
        #expect(MCPConnectionBridge.isSearchable(entry(.editor), by: "jan", masksValues: true))
    }

    @Test("A search on a connection with rules leaves withheld sources out of the storage query, so they take no slot")
    func searchLeavesWithheldSourcesOutOfTheQuery() {
        let all = Set(QueryHistorySource.allCases)
        let searched = MCPConnectionBridge.searchableSources(by: "jan", masksValues: true)
        #expect(!searched.contains(.rowEdit))
        #expect(!searched.contains(.dataImport))
        #expect(searched == all.subtracting([.rowEdit, .dataImport]))
        #expect(MCPConnectionBridge.searchableSources(by: nil, masksValues: true) == all)
        #expect(MCPConnectionBridge.searchableSources(by: "", masksValues: true) == all)
        #expect(MCPConnectionBridge.searchableSources(by: "jan", masksValues: false) == all)
    }

    @Test("The dashboard hands MCP no session or slow statement text from a connection with rules")
    func dashboardStatementTextIsWithheld() throws {
        let provider = try #require(ServerDashboardQueryProviderFactory.provider(for: .postgresql))
        let session = DashboardSession(
            id: "7", user: "app", database: "shop", state: "idle", durationSeconds: 1, duration: "1s",
            query: "UPDATE users SET ssn = '123-45-6789' WHERE id = 1"
        )
        let slow = DashboardSlowQuery(duration: "2s", query: session.query, user: "app", database: "shop")

        #expect(
            MCPConnectionBridge.sessionPayload(session, provider: provider, withholdingQuery: true)["query"]?.stringValue
                == ServerErrorText.withheldStatementText
        )
        #expect(
            MCPConnectionBridge.slowQueryPayload(slow, withholdingQuery: true)["query"]?.stringValue
                == ServerErrorText.withheldStatementText
        )
        #expect(MCPConnectionBridge.sessionPayload(session, provider: provider)["query"]?.stringValue == session.query)
    }

    @Test("A partial commit keeps its account of what was written and loses only the server's words")
    func partialCommitKeepsItsAccount() throws {
        let partial = DataWritePartialCommitError(
            committed: [], totalStatements: 3, engine: "PostgreSQL", disposition: .written, underlying: EchoingServerError()
        )

        let withheld = try #require(ServerErrorText.withholding(partial) as? DataWritePartialCommitError)

        #expect(withheld.totalStatements == 3)
        #expect(withheld.disposition == .written)
        #expect(!(withheld.errorDescription ?? "").contains("jane@example.com"))
    }
}

private struct EchoingServerError: PluginDriverError {
    var pluginErrorMessage: String { #"invalid input syntax for type integer: "jane@example.com""# }
    var pluginSqlState: String? { "22P02" }
}

private final class EchoingDriver: PluginDriverStub, @unchecked Sendable {
    var capabilities: PluginCapabilities { [] }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        throw EchoingServerError()
    }
}
