//
//  ServerDashboardViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

@MainActor
struct ServerDashboardViewModelTests {
    private static let clickHouseQueryId = "3f2b8c1e-5d4a-4b6f-9a1e-2c7d8e9f0a1b"

    private func makeViewModel(databaseType: DatabaseType) -> ServerDashboardViewModel {
        ServerDashboardViewModel(connectionId: UUID(), databaseType: databaseType, services: .live)
    }

    private func session(
        from viewModel: ServerDashboardViewModel,
        columns: [String],
        row: [String]
    ) async throws -> DashboardSession {
        let provider = try #require(viewModel.provider)
        let sessions = try await provider.fetchSessions { _ in
            QueryResult(
                columns: columns,
                columnTypes: [],
                rows: [row.map { PluginCellValue.text($0) }],
                rowsAffected: 0,
                executionTime: 0,
                error: nil
            )
        }
        return try #require(sessions.first)
    }

    private func mySQLSession(_ viewModel: ServerDashboardViewModel) async throws -> DashboardSession {
        try await session(
            from: viewModel,
            columns: ["ID", "USER", "DB", "COMMAND", "TIME", "STATE", "INFO"],
            row: ["42", "app", "shop", "Query", "3", "executing", "SELECT SLEEP(3)"]
        )
    }

    private func mssqlSession(_ viewModel: ServerDashboardViewModel) async throws -> DashboardSession {
        try await session(
            from: viewModel,
            columns: ["session_id", "login_name", "db_name", "status", "duration_ms", "command", "query_text"],
            row: ["57", "sa", "master", "running", "1200", "SELECT", "WAITFOR DELAY '00:00:03'"]
        )
    }

    private func clickHouseSession(
        _ viewModel: ServerDashboardViewModel,
        queryId: String = clickHouseQueryId
    ) async throws -> DashboardSession {
        try await session(
            from: viewModel,
            columns: ["query_id", "user", "current_database", "elapsed", "read_rows", "memory_usage", "query"],
            row: [queryId, "default", "default", "2.5", "100", "2048", "SELECT sleep(3)"]
        )
    }

    private func postgresSession(_ viewModel: ServerDashboardViewModel) async throws -> DashboardSession {
        try await session(
            from: viewModel,
            columns: ["pid", "usename", "datname", "state", "duration_secs", "query"],
            row: ["1733", "postgres", "app", "active", "3", "SELECT pg_sleep(3)"]
        )
    }

    @Test("MySQL dashboard exposes sessions, metrics, and slow queries")
    func mySQLSupportedPanels() {
        let vm = makeViewModel(databaseType: .mysql)
        #expect(vm.supportedPanels == [.activeSessions, .serverMetrics, .slowQueries])
        #expect(vm.isSupported)
    }

    @Test("PostgreSQL dashboard exposes sessions, metrics, and slow queries")
    func postgresSupportedPanels() {
        let vm = makeViewModel(databaseType: .postgresql)
        #expect(vm.supportedPanels == [.activeSessions, .serverMetrics, .slowQueries])
    }

    @Test("SQLite and DuckDB return no provider and an empty dashboard", arguments: [DatabaseType.sqlite, .duckdb])
    func fileEnginesHaveNoDashboard(_ databaseType: DatabaseType) {
        let vm = makeViewModel(databaseType: databaseType)
        #expect(vm.supportedPanels.isEmpty)
        #expect(!vm.isSupported)
    }

    @Test("Oracle, MongoDB and Redis show sessions, metrics, and slow queries", arguments: [
        DatabaseType.oracle, .mongodb, .redis,
    ])
    func documentAndKeyValueEnginesHaveADashboard(_ databaseType: DatabaseType) {
        let vm = makeViewModel(databaseType: databaseType)
        #expect(vm.supportedPanels == [.activeSessions, .serverMetrics, .slowQueries])
        #expect(vm.isSupported)
    }

    @Test("Redis terminates any client and cancels only a blocked one", arguments: [("N", false), ("b", true)])
    func redisCancelsOnlyABlockedClient(flags: String, cancellable: Bool) async throws {
        let vm = makeViewModel(databaseType: .redis)
        let session = try await session(
            from: vm,
            columns: ["result"],
            row: ["id=21 addr=10.0.0.4:51022 idle=4 flags=\(flags) db=0 cmd=blpop user=default"]
        )
        #expect(vm.canKill(session))
        #expect(vm.canCancel(session) == cancellable)
    }

    @Test("MongoDB cancels a running operation and has no connection to terminate")
    func mongoCancelsOnly() async throws {
        let vm = makeViewModel(databaseType: .mongodb)
        let session = try await session(
            from: vm,
            columns: ["active", "connection", "opid", "secs"],
            row: ["true", "conn12", "31745", "3"]
        )
        #expect(!vm.canKill(session))
        #expect(vm.canCancel(session))
    }

    @Test("Oracle terminates and cancels a session named by SID and serial number")
    func oracleKillsAndCancels() async throws {
        let vm = makeViewModel(databaseType: .oracle)
        let session = try await session(
            from: vm,
            columns: ["SESSION_ID", "USERNAME", "SCHEMANAME", "STATUS", "LAST_CALL_ET", "SQL_TEXT"],
            row: ["55,59756", "APP", "APP", "ACTIVE", "3", "SELECT 1 FROM DUAL"]
        )
        #expect(vm.canKill(session))
        #expect(vm.canCancel(session))
    }

    @Test("MySQL supports both kill session and cancel query")
    func mySQLKillAndCancelCapabilities() async throws {
        let vm = makeViewModel(databaseType: .mysql)
        let session = try await mySQLSession(vm)
        #expect(vm.canKill(session))
        #expect(vm.canCancel(session))
    }

    @Test("MSSQL supports kill session but not cancel query")
    func mssqlKillButNoCancel() async throws {
        let vm = makeViewModel(databaseType: .mssql)
        let session = try await mssqlSession(vm)
        #expect(vm.canKill(session))
        #expect(!vm.canCancel(session))
    }

    @Test("ClickHouse terminates a running query by its query id, and has no separate cancel")
    func clickHouseKillsByQueryId() async throws {
        let vm = makeViewModel(databaseType: .clickhouse)
        let session = try await clickHouseSession(vm)
        #expect(vm.canKill(session))
        #expect(!vm.canCancel(session))
    }

    @Test("ClickHouse offers no Terminate for a query id it cannot quote safely")
    func clickHouseRefusesAnUnsafeQueryId() async throws {
        let vm = makeViewModel(databaseType: .clickhouse)
        let session = try await clickHouseSession(vm, queryId: "etl'; DROP TABLE t; --")
        #expect(!vm.canKill(session))
    }

    @Test(
        "The dashboard and MCP give the same kill and cancel answer for a session",
        arguments: [DatabaseType.mysql, .mssql, .clickhouse, .postgresql]
    )
    func dashboardAndMCPAgree(databaseType: DatabaseType) async throws {
        let vm = makeViewModel(databaseType: databaseType)
        let provider = try #require(vm.provider)
        let session: DashboardSession
        switch databaseType {
        case .mysql:
            session = try await mySQLSession(vm)
        case .mssql:
            session = try await mssqlSession(vm)
        case .clickhouse:
            session = try await clickHouseSession(vm)
        default:
            session = try await postgresSession(vm)
        }
        let payload = MCPConnectionBridge.sessionPayload(session, provider: provider)
        #expect(payload["can_kill"]?.boolValue == vm.canKill(session))
        #expect(payload["can_cancel"]?.boolValue == vm.canCancel(session))
    }

    private func listed(_ id: String, user: String = "app") -> DashboardSession {
        DashboardSession(
            id: id, user: user, database: "shop", state: "active", durationSeconds: 1, duration: "1s", query: "SELECT 1"
        )
    }

    @Test("confirmKillSession stores the session and shows confirmation")
    func confirmKillSessionUpdatesState() {
        let vm = makeViewModel(databaseType: .mysql)
        vm.confirmKillSession(listed("42"))
        #expect(vm.pendingKillSession?.id == "42")
        #expect(vm.showKillConfirmation)
    }

    @Test("confirmCancelQuery stores the session and shows confirmation")
    func confirmCancelQueryUpdatesState() {
        let vm = makeViewModel(databaseType: .mysql)
        vm.confirmCancelQuery(listed("99"))
        #expect(vm.pendingCancelSession?.id == "99")
        #expect(vm.showCancelConfirmation)
    }

    @Test("The Terminate and Cancel confirmations name the session's PID and user")
    func confirmationsNameTheSession() {
        let session = listed("57", user: "sa")
        #expect(ServerDashboardViewModel.killConfirmationMessage(for: session)
            == "Terminate session 57 (user sa)? Any running queries will be aborted.")
        #expect(ServerDashboardViewModel.cancelConfirmationMessage(for: session)
            == "Cancel the running query for session 57 (user sa)?")
    }

    @Test("A session the server lists with no user is named by its PID alone")
    func confirmationsWithoutAUser() {
        let session = listed("1733", user: "")
        #expect(ServerDashboardViewModel.killConfirmationMessage(for: session)
            == "Terminate session 1733? Any running queries will be aborted.")
        #expect(ServerDashboardViewModel.cancelConfirmationMessage(for: session)
            == "Cancel the running query for session 1733?")
    }

    @Test("A selected session that ends leaves the selection, and a new session reusing its id starts unselected")
    func endedSessionLeavesTheSelection() {
        let vm = makeViewModel(databaseType: .mssql)
        vm.sessions = [listed("57"), listed("60")]
        vm.sessionSelection.ids = ["57"]

        vm.sessions = [listed("60")]
        #expect(vm.sessionSelection.ids.isEmpty)

        vm.sessions = [listed("60"), listed("57", user: "other")]
        #expect(vm.sessionSelection.ids.isEmpty)
        #expect(SessionGridColumns.actionTarget(vm.sessionSelection.ids, in: vm.sessions) == nil)
    }

    @Test("A refresh that still lists the selected session keeps it selected")
    func listedSessionKeepsItsSelection() {
        let vm = makeViewModel(databaseType: .postgresql)
        vm.sessions = [listed("10"), listed("7")]
        vm.sessionSelection.ids = ["10", "7"]

        vm.sessions = [listed("7"), listed("10"), listed("12")]
        #expect(vm.sessionSelection.ids == ["10", "7"])

        vm.sessions = [listed("10")]
        #expect(vm.sessionSelection.ids == ["10"])
    }

    @Test("stopAutoRefresh clears the refreshing flag")
    func stopAutoRefreshClearsRefreshingFlag() {
        let vm = makeViewModel(databaseType: .mysql)
        vm.isRefreshing = true
        vm.stopAutoRefresh()
        #expect(!vm.isRefreshing)
    }
}
