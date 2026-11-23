//
//  StatementSchemaScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import TableProTestSupport
import Testing

private actor DiscardingHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

private final class SchemaRecordingDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var schemas: [String?] = []

    var requestedSchemas: [String?] { lock.withLock { schemas } }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        lock.withLock { schemas.append(schema) }
        return [PluginTableInfo(name: "orders", type: "TABLE", schema: schema)]
    }
}

// On SQL Server a schema switch only labels the session, so SQL the caller wrote still resolves its names in dbo. A
// schema named for such SQL is refused; a tool that names the schema in the SQL it builds keeps taking one.
@MainActor
struct StatementSchemaScopeTests {
    private func session(_ type: DatabaseType, browseSchema: String? = nil) -> ScriptAnsweringDriver {
        var connection = TestFixtures.makeConnection(database: "warehouse", type: type)
        connection.aiPolicy = .alwaysAllow
        let driver = ScriptAnsweringDriver(connection: connection)
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        session.browseSchema = browseSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return driver
    }

    private func services(gate: any ExecutionGate = AlwaysAllowGate()) -> MCPToolServices {
        MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil },
                connectionIdsProvider: { [] },
                historyRecorder: DiscardingHistory(),
                executionGate: gate
            )
        )
    }

    private func executeQuery(
        _ driver: ScriptAnsweringDriver,
        schema: String?,
        gate: any ExecutionGate = AlwaysAllowGate()
    ) async throws -> MCPToolCallResult {
        var arguments: [String: JsonValue] = [
            "connection_id": .string(driver.connection.id.uuidString),
            "query": .string("SELECT * FROM orders")
        ]
        if let schema { arguments["schema"] = .string(schema) }
        return try await ExecuteQueryTool().perform(
            arguments: .object(arguments),
            context: MCPToolTestHarness.context(),
            services: services(gate: gate)
        )
    }

    @Test("SQL Server execute_query naming another schema is refused before anything runs")
    func sqlServerExecuteQueryRefusesAnotherSchema() async {
        let driver = session(.mssql, browseSchema: "dbo")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        await #expect(throws: (any Error).self) {
            _ = try await executeQuery(driver, schema: "archive")
        }

        #expect(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty)
    }

    @Test("SQL Server execute_query naming even the session's schema label is refused, since execution ignores it")
    func sqlServerExecuteQueryRefusesTheSessionLabel() async {
        let driver = session(.mssql, browseSchema: "dbo")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        await #expect(throws: (any Error).self) {
            _ = try await executeQuery(driver, schema: "dbo")
        }

        #expect(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty)
    }

    @Test("SQL Server execute_query without a schema runs unqualified, and Safe Mode is asked about no schema")
    func sqlServerExecuteQueryNamesNoSchema() async throws {
        let driver = session(.mssql, browseSchema: "archive")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let gate = RequestRecordingGate(allows: true)

        let result = try await executeQuery(driver, schema: nil, gate: gate)

        let request = try #require(await gate.requests.first)
        #expect(!result.isError)
        #expect(request.scope?.database == "warehouse")
        #expect(request.scope?.schema == nil)
    }

    @Test("The chat card on SQL Server names the database and no schema")
    func sqlServerCardNamesNoSchema() async throws {
        let driver = session(.mssql, browseSchema: "archive")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let registry = ChatToolRegistry()
        registry.registerBuiltIn(ConfirmDestructiveOperationChatTool())
        let viewModel = AIChatViewModel()
        viewModel.connection = driver.connection
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        let sessionId = viewModel.sessionId
        let call = ToolUseBlock(
            id: "call_1",
            name: ConfirmDestructiveOperationChatTool().name,
            input: .object([
                "query": .string("DROP TABLE orders"),
                "confirmation_phrase": .string(ConfirmDestructiveOperationChatTool.requiredPhrase)
            ])
        )

        let approvals = Task {
            await viewModel.resolveAndAwaitApprovals(assembledBlocks: [call], assistantID: assistant.id, registry: registry)
        }
        try await waitUntil { ToolApprovalCenter.shared.isAwaiting(sessionId: sessionId, toolUseId: "call_1") }
        let drawn = ToolApprovalCenter.shared.shownScope(sessionId: sessionId, toolUseId: "call_1")
        ToolApprovalCenter.shared.resolve(sessionId: sessionId, toolUseId: "call_1", decision: .cancel)
        _ = await approvals.value

        #expect(drawn?.database == "warehouse")
        #expect(drawn != nil && drawn?.schema == nil)
    }

    @Test("PostgreSQL execute_query still runs in another schema")
    func postgresExecuteQueryTakesAnotherSchema() async throws {
        let driver = session(.postgresql, browseSchema: "public")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let result = try await executeQuery(driver, schema: "archive")

        #expect(!result.isError)
        #expect(!(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty))
    }

    @Test("The assistant's confirm_destructive_operation on SQL Server naming another schema is refused before approval")
    func sqlServerChatDestructiveRefusesAnotherSchema() async {
        let driver = session(.mssql, browseSchema: "dbo")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let gate = RequestRecordingGate(allows: true)
        let context = ChatToolContext(
            connectionId: driver.connection.id,
            bridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil },
                connectionIdsProvider: { [] },
                historyRecorder: DiscardingHistory(),
                executionGate: gate
            ),
            chatMode: .agent,
            sessionId: UUID(),
            approvalWasExplicit: true,
            policyLookup: { _ in .alwaysAllow }
        )

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await ConfirmDestructiveOperationChatTool().execute(
                input: .object([
                    "query": .string("DROP TABLE orders"),
                    "confirmation_phrase": .string(ConfirmDestructiveOperationChatTool.requiredPhrase),
                    "schema": .string("archive")
                ]),
                context: context
            )
        }

        #expect(await gate.requests.isEmpty)
        #expect(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty)
    }

    @Test("The chat card never offers a SQL Server call in a schema its statement cannot run in")
    func chatCardRefusesAnUnrunnableSchema() async throws {
        let driver = session(.mssql, browseSchema: "dbo")
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let registry = ChatToolRegistry()
        registry.registerBuiltIn(ConfirmDestructiveOperationChatTool())
        let viewModel = AIChatViewModel()
        viewModel.connection = driver.connection
        let assistant = ChatTurn(role: .assistant, blocks: [], modelId: "test-model", providerId: nil)
        viewModel.messages.append(assistant)
        let sessionId = viewModel.sessionId
        let call = ToolUseBlock(
            id: "call_1",
            name: ConfirmDestructiveOperationChatTool().name,
            input: .object([
                "query": .string("DROP TABLE orders"),
                "confirmation_phrase": .string(ConfirmDestructiveOperationChatTool.requiredPhrase),
                "schema": .string("archive")
            ])
        )
        defer { ToolApprovalCenter.shared.cancelAll(sessionId: sessionId) }

        let approvals = Task {
            await viewModel.resolveAndAwaitApprovals(assembledBlocks: [call], assistantID: assistant.id, registry: registry)
        }
        let resolved = try #require(await BoundedCall.result { await approvals.value })

        let state = try #require(resolved.blocks.first?.approvalState)
        if case .denied = state {} else {
            Issue.record("Expected the call to be refused before its card asked, got \(state)")
        }
        #expect(resolved.explicitlyApproved.isEmpty)
    }

    // The session and a pooled metadata connection both read through the one recording driver, whichever route serves.
    private func recordingSession(
        _ type: DatabaseType,
        database: String,
        schema: String
    ) async throws -> (id: UUID, driver: SchemaRecordingDriver) {
        var connection = TestFixtures.makeConnection(database: database, type: type)
        connection.aiPolicy = .alwaysAllow
        let recording = SchemaRecordingDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: recording)
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let pooled = PluginDriverAdapter(connection: connection, pluginDriver: recording)
        try await pooled.connect()
        MetadataConnectionPool.shared.injectEntry(
            pooled, scope: DatabaseScope(connectionId: connection.id, database: database, schema: schema)
        )
        return (connection.id, recording)
    }

    private func removeRecordingSession(_ id: UUID) {
        MetadataConnectionPool.shared.closeAll(connectionId: id)
        DatabaseManager.shared.removeSession(for: id)
    }

    private func listTables(_ id: UUID, _ scope: [String: JsonValue]) async throws -> MCPToolCallResult {
        try await ListTablesTool().perform(
            arguments: .object(scope.merging(["connection_id": .string(id.uuidString)]) { first, _ in first }),
            context: MCPToolTestHarness.context(),
            services: services()
        )
    }

    @Test("SQL Server list_tables still reads another schema, which it names to the driver")
    func sqlServerListTablesTakesASchema() async throws {
        let (id, recording) = try await recordingSession(.mssql, database: "warehouse", schema: "archive")
        defer { removeRecordingSession(id) }

        let result = try await listTables(id, ["schema": .string("archive")])

        #expect(!result.isError)
        #expect(result.structuredContent?["schema"]?.stringValue == "archive")
        #expect(recording.requestedSchemas.contains("archive"))
    }

    @Test("SQLite list_tables reads an attached database named as the schema")
    func sqliteListTablesReadsAnAttachedSchema() async throws {
        let (id, recording) = try await recordingSession(.sqlite, database: "prod.sqlite", schema: "auth")
        defer { removeRecordingSession(id) }

        let result = try await listTables(id, ["schema": .string("auth")])

        let tables = result.structuredContent?["tables"]?.arrayValue ?? []
        #expect(!result.isError)
        #expect(recording.requestedSchemas.contains("auth"))
        #expect(tables.count == 1)
    }

    @Test("SQLite list_tables naming another database file is still refused, since the connection reads only its own")
    func sqliteListTablesRefusesAnotherFile() async throws {
        let (id, recording) = try await recordingSession(.sqlite, database: "prod.sqlite", schema: "auth")
        defer { removeRecordingSession(id) }

        await #expect(throws: (any Error).self) {
            _ = try await listTables(id, ["database": .string("staging.sqlite")])
        }
        #expect(recording.requestedSchemas.isEmpty)
    }

    @Test("SQLite execute_query naming an attached schema is still refused, since SQL runs unqualified there")
    func sqliteExecuteQueryRefusesASchema() async {
        let driver = session(.sqlite)
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        await #expect(throws: (any Error).self) {
            _ = try await executeQuery(driver, schema: "auth")
        }

        #expect(driver.sentStatements.isEmpty && driver.sentBatches.isEmpty)
    }
}
