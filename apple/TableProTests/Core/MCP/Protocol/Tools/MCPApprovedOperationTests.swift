//
//  MCPApprovedOperationTests.swift
//  TableProTests
//
//  What a person approves over MCP is the operation that runs: its database and schema, every statement with its
//  values, and a read that Safe Mode asks about like any other.
//

import Foundation
import os
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

// Writes maintenance the way SQLite's builder does: no form reaches one schema without a table.
private final class SchemaWideMaintenanceDriver: PluginDriverStub, @unchecked Sendable {
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])

    var received: [String] { log.withLock { $0 } }

    func sessionTransactionState() async -> PluginSessionTransactionState { .idle }

    func maintenanceOperations() -> [PluginMaintenanceOperation]? {
        [PluginMaintenanceOperation(name: "REINDEX", appliesTo: [.table], scope: .objectOrDatabase)]
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        if let table { return ["REINDEX \(schema.map { "\($0)." } ?? "")\(table)"] }
        return schema == nil ? ["REINDEX"] : nil
    }

    func execute(query: String) async throws -> PluginQueryResult {
        log.withLock { $0.append(query) }
        return .empty
    }
}

// Approves after the connection reconnected under the person still deciding.
private struct ReconnectingWhileAskedGate: ExecutionGate {
    let connectionId: UUID

    func authorize(_ request: OperationRequest) async -> OperationDecision {
        try? await DatabaseManager.shared.reconnectSession(connectionId)
        return await AlwaysAllowGate().authorize(request)
    }
}

extension GlobalStateSuites {
    @MainActor
    struct MCPApprovedOperationTests {
        private func rig(
            type: DatabaseType = .postgresql,
            safeMode: SafeModeLevel,
            answer: WritePolicyPrompts.Answer = .approveAll,
            executionGate: (any ExecutionGate)? = nil
        ) -> WritePolicyRig {
            WritePolicyRig(
                connection: WritePolicyRig.connection(
                    type: type,
                    externalAccess: .readWrite,
                    aiPolicy: .alwaysAllow,
                    safeMode: safeMode
                ),
                prompts: WritePolicyPrompts(answer),
                live: true,
                executionGate: executionGate
            )
        }

        private func confirmingGate(_ sheet: StubConfirming, level: SafeModeLevel) -> DefaultExecutionGate {
            DefaultExecutionGate(
                confirming: sheet,
                authenticating: StubAuthenticating(answer: true),
                safeModeLevelResolver: { _ in level },
                forcesWriteResolver: { _ in false },
                auditLog: WritePolicyAuditLog()
            )
        }

        private func handle(
            _ tool: String,
            _ arguments: [String: JsonValue],
            on rig: WritePolicyRig,
            scopes: Set<MCPScope> = MCPScope.readWriteSet
        ) async throws -> MCPResult {
            var fields = arguments
            fields["connection_id"] = .string(rig.connection.id.uuidString)
            let params = MCPToolTestHarness.toolCallParams(name: tool, arguments: .object(fields))
            let handler = ToolsCallHandler(services: MCPToolServices(
                connectionBridge: MCPConnectionBridge(),
                authPolicy: rig.authPolicy,
                settingsProvider: { MCPSettings() },
                queryHistoryManager: ToolTestQueryHistoryStore()
            ))
            return try await handler.handle(
                params: params,
                context: MCPToolTestHarness.context(params: params, principal: MCPToolTestHarness.principal(scopes: scopes))
            )
        }

        private static func errorText(_ result: MCPResult) -> String {
            result.payload["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        }

        // MARK: - The scope a statement runs in

        struct ScopedCall: Sendable, CustomTestStringConvertible {
            let tool: String
            let type: DatabaseType
            let arguments: [String: JsonValue]
            let scopes: Set<MCPScope>
            let shown: String

            var testDescription: String { tool }
        }

        nonisolated private static let scopedCalls = [
            ScopedCall(
                tool: ExecuteQueryTool.name,
                type: .postgresql,
                arguments: ["query": .string("DELETE FROM orders WHERE total >= 0")],
                scopes: MCPScope.readWriteSet,
                shown: "DELETE FROM orders WHERE total >= 0"
            ),
            ScopedCall(
                tool: ConfirmDestructiveOperationTool.name,
                type: .postgresql,
                arguments: ["query": .string("DROP TABLE orders")],
                scopes: MCPScope.fullAccessSet,
                shown: "DROP TABLE orders"
            ),
            ScopedCall(
                tool: ExplainQueryTool.name,
                type: .cockroachdb,
                arguments: ["query": .string("UPDATE orders SET total = 0 WHERE id = 1"), "analyze": .bool(true)],
                scopes: MCPScope.readWriteSet,
                shown: "UPDATE orders SET total = 0 WHERE id = 1"
            )
        ]

        @Test("The confirmation names the database and schema the client picked", arguments: scopedCalls)
        func confirmationNamesTheScope(call: ScopedCall) async throws {
            let sheet = StubConfirming(answer: false)
            let rig = rig(type: call.type, safeMode: .alert, executionGate: confirmingGate(sheet, level: .alert))
            defer { rig.tearDown() }

            let result = try await handle(
                call.tool,
                call.arguments.merging(["database": .string("production"), "schema": .string("sales")]) { first, _ in first },
                on: rig,
                scopes: call.scopes
            )

            let request = try #require(sheet.lastRequest)
            #expect(request.scope?.database == "production")
            #expect(request.scope?.schema == "sales")
            let subtitle = OperationConfirmationPrompt.subtitle(of: request)
            #expect(subtitle.contains("production"))
            #expect(subtitle.contains("sales"))
            #expect(OperationConfirmationPrompt.statements(of: request).contains { $0.contains(call.shown) })
            #expect(result.payload["isError"]?.boolValue == true)
            #expect(rig.driver.received.isEmpty)
        }

        @Test("The approval an eliciting client is sent names the database and schema")
        func elicitationNamesTheScope() async throws {
            let rig = rig(safeMode: .alert, executionGate: RequestRecordingGate(allows: false))
            defer { rig.tearDown() }
            let arguments: JsonValue = .object([
                "connection_id": .string(rig.connection.id.uuidString),
                "query": .string("DELETE FROM orders WHERE total >= 0"),
                "database": .string("production"),
                "schema": .string("sales")
            ])
            let params = MCPToolTestHarness.toolCallParams(name: ExecuteQueryTool.name, arguments: arguments)
            let context = MCPToolTestHarness.context(
                params: params,
                principal: MCPToolTestHarness.principal(scopes: MCPScope.fullAccessSet),
                clientCapabilities: MCPToolTestHarness.elicitingClient()
            )

            do {
                _ = try await ExecuteQueryTool().call(
                    arguments: arguments,
                    context: context,
                    services: MCPToolServices(
                        connectionBridge: MCPConnectionBridge(),
                        authPolicy: rig.authPolicy,
                        settingsProvider: { MCPSettings() },
                        queryHistoryManager: ToolTestQueryHistoryStore()
                    )
                )
                Issue.record("Expected the approval to be elicited")
            } catch let signal as MCPInputRequired {
                let message = signal.inputRequests.first?.message ?? ""
                #expect(message.contains("'production'"))
                #expect(message.contains("'sales'"))
            }
            #expect(rig.driver.received.isEmpty)
        }

        // Oracle's driver reports no database, so the statement names none, yet it still runs in the schema it names.
        @Test("On Oracle the confirmation names the schema the DROP runs in, with no database")
        func oracleConfirmationNamesTheSchema() async throws {
            let sheet = StubConfirming(answer: false)
            let rig = rig(type: .oracle, safeMode: .alert, executionGate: confirmingGate(sheet, level: .alert))
            defer { rig.tearDown() }

            _ = try await handle(
                ConfirmDestructiveOperationTool.name,
                ["query": .string("DROP TABLE orders"), "schema": .string("HR")],
                on: rig,
                scopes: MCPScope.fullAccessSet
            )

            let request = try #require(sheet.lastRequest)
            #expect(request.scope?.schema == "HR")
            #expect(OperationConfirmationPrompt.subtitle(of: request).contains("HR"))
            #expect(rig.driver.received.isEmpty)
        }

        @Test("On Oracle the elicited approval names the schema the DROP runs in")
        func oracleElicitationNamesTheSchema() async throws {
            let rig = rig(type: .oracle, safeMode: .alert, executionGate: RequestRecordingGate(allows: false))
            defer { rig.tearDown() }
            let arguments: JsonValue = .object([
                "connection_id": .string(rig.connection.id.uuidString),
                "query": .string("DROP TABLE orders"),
                "schema": .string("HR")
            ])
            let params = MCPToolTestHarness.toolCallParams(name: ConfirmDestructiveOperationTool.name, arguments: arguments)
            let context = MCPToolTestHarness.context(
                params: params,
                principal: MCPToolTestHarness.principal(scopes: MCPScope.fullAccessSet),
                clientCapabilities: MCPToolTestHarness.elicitingClient()
            )

            do {
                _ = try await ConfirmDestructiveOperationTool().call(
                    arguments: arguments,
                    context: context,
                    services: MCPToolServices(
                        connectionBridge: MCPConnectionBridge(),
                        authPolicy: rig.authPolicy,
                        settingsProvider: { MCPSettings() },
                        queryHistoryManager: ToolTestQueryHistoryStore()
                    )
                )
                Issue.record("Expected the approval to be elicited")
            } catch let signal as MCPInputRequired {
                #expect(signal.inputRequests.first?.message.contains("'HR'") == true)
            }
            #expect(rig.driver.received.isEmpty)
        }

        @Test("stop_server_session on Oracle, saved with a service name its driver never reports, runs")
        func oracleStopServerSessionRuns() async throws {
            let rig = rig(type: .oracle, safeMode: .silent)
            defer { rig.tearDown() }

            let result = try await handle(
                StopServerSessionTool.name,
                ["process_id": .string("12,34"), "mode": .string("kill")],
                on: rig
            )

            #expect(rig.connection.database == "matrix")
            #expect(result.payload["isError"]?.boolValue != true, "\(Self.errorText(result))")
            #expect(rig.driver.received.contains { $0.contains("KILL SESSION '12,34'") })
        }

        // MARK: - run_maintenance

        private func maintenanceRig(_ driver: SchemaWideMaintenanceDriver, gate: any ExecutionGate) -> WritePolicyRig {
            let connection = WritePolicyRig.connection(
                type: .postgresql, externalAccess: .readWrite, aiPolicy: .alwaysAllow, safeMode: .silent
            )
            return WritePolicyRig(
                connection: connection,
                prompts: WritePolicyPrompts(.approveAll),
                live: true,
                executionGate: gate,
                sessionDriver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
            )
        }

        @Test("run_maintenance refuses a named schema its engine has no whole-schema form for, before anyone is asked")
        func schemaWideMaintenanceIsRefusedBeforeApproval() async throws {
            let gate = RequestRecordingGate(allows: true)
            let driver = SchemaWideMaintenanceDriver()
            let rig = maintenanceRig(driver, gate: gate)
            defer { rig.tearDown() }

            let result = try await handle(
                RunMaintenanceTool.name, ["operation": .string("REINDEX"), "schema": .string("auth")], on: rig
            )

            #expect(result.payload["isError"]?.boolValue == true)
            #expect(Self.errorText(result).contains("Pass 'table'"))
            #expect(await gate.requests.isEmpty)
            #expect(driver.received.isEmpty)
        }

        @Test("run_maintenance with no table runs on the whole database when the schema was only the one browsed")
        func browsedSchemaIsLeftOutOfADatabaseWideForm() async throws {
            let gate = RequestRecordingGate(allows: true)
            let driver = SchemaWideMaintenanceDriver()
            let rig = maintenanceRig(driver, gate: gate)
            defer { rig.tearDown() }
            DatabaseManager.shared.updateSession(rig.connection.id) { $0.browseSchema = "auth" }

            let result = try await handle(RunMaintenanceTool.name, ["operation": .string("REINDEX")], on: rig)

            #expect(result.payload["isError"]?.boolValue != true, "\(Self.errorText(result))")
            let request = try #require(await gate.requests.first)
            #expect(request.scope?.schema == nil)
            #expect(driver.received == ["REINDEX"])
        }

        // MARK: - A statement that moves the connection

        @Test("After USE production, a DELETE naming no database never runs, and one naming production does")
        func deleteAfterAUseNeedsADatabase() async throws {
            var connection = WritePolicyRig.connection(
                type: .mysql, externalAccess: .readWrite, aiPolicy: .alwaysAllow, safeMode: .silent
            )
            connection.database = ""
            let rig = WritePolicyRig(connection: connection, prompts: WritePolicyPrompts(.approveAll), live: true)
            defer { rig.tearDown() }
            let delete = "DELETE FROM orders WHERE id = 1"

            let use = try await handle(ExecuteQueryTool.name, ["query": .string("USE production")], on: rig)
            let unnamed = try await handle(ExecuteQueryTool.name, ["query": .string(delete)], on: rig)

            #expect(use.payload["isError"]?.boolValue != true, "\(Self.errorText(use))")
            #expect(unnamed.payload["isError"]?.boolValue == true)
            #expect(Self.errorText(unnamed).contains("Pass database"))
            #expect(!rig.driver.received.contains(delete))

            let named = try await handle(
                ExecuteQueryTool.name, ["query": .string(delete), "database": .string("production")], on: rig
            )

            #expect(named.payload["isError"]?.boolValue != true, "\(Self.errorText(named))")
            #expect(rig.driver.received.contains(delete))
        }

        // MARK: - create_database

        private func elicitedMessage(
            _ tool: some MCPToolImplementation,
            _ arguments: [String: JsonValue],
            on rig: WritePolicyRig
        ) async throws -> String? {
            var fields = arguments
            fields["connection_id"] = .string(rig.connection.id.uuidString)
            let params = MCPToolTestHarness.toolCallParams(name: type(of: tool).name, arguments: .object(fields))
            let context = MCPToolTestHarness.context(
                params: params,
                principal: MCPToolTestHarness.principal(scopes: MCPScope.fullAccessSet),
                clientCapabilities: MCPToolTestHarness.elicitingClient()
            )
            do {
                _ = try await tool.call(
                    arguments: .object(fields),
                    context: context,
                    services: MCPToolServices(
                        connectionBridge: MCPConnectionBridge(),
                        authPolicy: rig.authPolicy,
                        settingsProvider: { MCPSettings() },
                        queryHistoryManager: ToolTestQueryHistoryStore()
                    )
                )
                return nil
            } catch let signal as MCPInputRequired {
                return signal.inputRequests.first?.message
            }
        }

        // BigQuery's datasets are created and dropped inside the project it signed in to.
        @Test("Dropping a database on BigQuery is approved naming the project its driver reported")
        func bigQueryDropNamesTheReportedProject() async throws {
            let rig = rig(type: .bigQuery, safeMode: .alert, executionGate: RequestRecordingGate(allows: false))
            defer { rig.tearDown() }
            var session = try #require(DatabaseManager.shared.session(for: rig.connection.id))
            session.openedDatabase = "production"
            DatabaseManager.shared.injectSession(session, for: rig.connection.id)

            let message = try await elicitedMessage(
                DropDatabaseObjectTool(), ["kind": .string("database"), "name": .string("analytics")], on: rig
            )

            #expect(message?.contains("database 'production'") == true)
            #expect(rig.driver.received.isEmpty)
        }

        @Test("Creating a database on PostgreSQL is approved as server work, naming no database")
        func postgresCreateNamesNoDatabase() async throws {
            let rig = rig(type: .postgresql, safeMode: .alert, executionGate: RequestRecordingGate(allows: false))
            defer { rig.tearDown() }

            let message = try #require(try await elicitedMessage(CreateDatabaseTool(), ["name": .string("reports")], on: rig))

            #expect(message.contains("'reports'"))
            #expect(!message.contains(", database '"))
            #expect(rig.driver.received.isEmpty)
        }

        // Saved and not connected: the tool connects it through the SQL Server stand-in plugin.
        private func disconnectedRig(gate: (UUID) -> any ExecutionGate) -> WritePolicyRig {
            FakeMSSQLPluginRegistration.registerIfNeeded()
            let connection = WritePolicyRig.connection(
                type: .mssql, externalAccess: .readWrite, aiPolicy: .alwaysAllow, safeMode: .silent
            )
            let rig = WritePolicyRig(
                connection: connection, prompts: WritePolicyPrompts(.approveAll), live: true, executionGate: gate(connection.id)
            )
            DatabaseManager.shared.removeSession(for: connection.id)
            return rig
        }

        private func tearDownConnected(_ rig: WritePolicyRig) async {
            let id = rig.connection.id
            await DatabaseManager.shared.stopHealthMonitor(for: id)
            DatabaseManager.shared.driver(for: id)?.disconnect()
            FakeMSSQLPlugin.clearDatabasesCreated(on: id)
            rig.tearDown()
        }

        @Test("create_database on a saved connection that is not connected yet is approved and runs")
        func createDatabaseOnADisconnectedConnectionRuns() async throws {
            let rig = disconnectedRig { _ in AlwaysAllowGate() }

            let result = try await handle(
                CreateDatabaseTool.name, ["name": .string("reports")], on: rig, scopes: MCPScope.fullAccessSet
            )

            #expect(result.payload["isError"]?.boolValue != true, "\(Self.errorText(result))")
            #expect(FakeMSSQLPlugin.databasesCreated(on: rig.connection.id) == ["reports"])
            await tearDownConnected(rig)
        }

        @Test("create_database approved before the connection reconnected is refused on the new connection")
        func createDatabaseAfterAReconnectIsRefused() async throws {
            let rig = disconnectedRig { ReconnectingWhileAskedGate(connectionId: $0) }

            let result = try await handle(
                CreateDatabaseTool.name, ["name": .string("reports")], on: rig, scopes: MCPScope.fullAccessSet
            )

            #expect(result.payload["isError"]?.boolValue == true)
            #expect(Self.errorText(result).contains("The connection changed after this was approved"))
            #expect(FakeMSSQLPlugin.databasesCreated(on: rig.connection.id).isEmpty)
            await tearDownConnected(rig)
        }

        // MARK: - insert_rows

        @Test("insert_rows shows each row with its values, and runs the statement it showed")
        func insertRowsShowsTheValuesItRuns() async throws {
            let sheet = StubConfirming(answer: true)
            let rig = rig(safeMode: .alert, executionGate: confirmingGate(sheet, level: .alert))
            defer { rig.tearDown() }

            let result = try await handle(
                InsertRowsTool.name,
                [
                    "table": .string("staff"),
                    "columns": .array([.string("email"), .string("role")]),
                    "rows": .array([.array([.string("mallory@attacker.example"), .string("admin")])])
                ],
                on: rig
            )

            #expect(result.payload["isError"]?.boolValue != true, "\(Self.errorText(result))")
            let request = try #require(sheet.lastRequest)
            let shown = OperationConfirmationPrompt.statements(of: request)
            #expect(shown.count == 1)
            #expect(shown.first?.contains("'mallory@attacker.example'") == true)
            #expect(shown.first?.contains("'admin'") == true)
            #expect(!(shown.first?.contains("…") ?? true))
            let approved = try #require(request.sql)
            #expect(rig.driver.received.filter { $0.hasPrefix("INSERT") } == [approved])
            #expect(rig.driver.receivedParameters == [[.text("mallory@attacker.example"), .text("admin")]])
        }

        // MARK: - Reads Safe Mode confirms

        @Test(
            "browse_table and count_rows ask Safe Mode as a read and stop when it says no",
            arguments: [BrowseTableTool.name, CountRowsTool.name]
        )
        func rowReadsAskTheGate(tool: String) async throws {
            let gate = RequestRecordingGate(allows: false)
            let rig = rig(type: .duckdb, safeMode: .alertFull, executionGate: gate)
            defer { rig.tearDown() }
            rig.driver.columns = [PluginColumnInfo(name: "id", dataType: "INTEGER")]

            let result = try await handle(tool, ["table": .string("salaries")], on: rig, scopes: MCPScope.readOnlySet)

            let requests = await gate.requests
            #expect(requests.count == 1)
            #expect(requests.first?.kind == .readQuery)
            #expect(requests.first?.scope?.connectionId == rig.connection.id)
            #expect(Self.errorText(result).hasPrefix("\(MCPToolErrorCode.denied.rawValue):"))
            #expect(rig.driver.received.isEmpty)
        }

        @Test(
            "browse_table and count_rows are confirmed at a level that confirms every query",
            arguments: [BrowseTableTool.name, CountRowsTool.name]
        )
        func rowReadsAreConfirmed(tool: String) async throws {
            let rig = rig(type: .duckdb, safeMode: .alertFull, answer: .refuseAll)
            defer { rig.tearDown() }
            rig.driver.columns = [PluginColumnInfo(name: "id", dataType: "INTEGER")]

            let result = try await handle(tool, ["table": .string("salaries")], on: rig, scopes: MCPScope.readOnlySet)

            #expect(rig.prompts.prompts == [.confirmation])
            #expect(Self.errorText(result).hasPrefix("\(MCPToolErrorCode.denied.rawValue):"))
            #expect(rig.driver.received.isEmpty)
        }
    }
}
