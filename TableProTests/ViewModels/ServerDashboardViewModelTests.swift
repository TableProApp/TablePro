//
//  ServerDashboardViewModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
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

    @Test("SQLite dashboard exposes only server metrics")
    func sqliteSupportedPanels() {
        let vm = makeViewModel(databaseType: .sqlite)
        #expect(vm.supportedPanels == [.serverMetrics])
        #expect(!vm.supportedPanels.contains(.slowQueries))
    }

    @Test("DuckDB dashboard exposes only server metrics")
    func duckDBSupportedPanels() {
        let vm = makeViewModel(databaseType: .duckdb)
        #expect(vm.supportedPanels == [.serverMetrics])
    }

    @Test("Redis returns no provider and an empty dashboard")
    func redisHasNoDashboard() {
        let vm = makeViewModel(databaseType: .redis)
        #expect(vm.supportedPanels.isEmpty)
        #expect(!vm.isSupported)
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

    @Test("confirmKillSession stores process id and shows confirmation")
    func confirmKillSessionUpdatesState() {
        let vm = makeViewModel(databaseType: .mysql)
        vm.confirmKillSession(processId: "42")
        #expect(vm.pendingKillProcessId == "42")
        #expect(vm.showKillConfirmation)
    }

    @Test("confirmCancelQuery stores process id and shows confirmation")
    func confirmCancelQueryUpdatesState() {
        let vm = makeViewModel(databaseType: .mysql)
        vm.confirmCancelQuery(processId: "99")
        #expect(vm.pendingCancelProcessId == "99")
        #expect(vm.showCancelConfirmation)
    }

    @Test("stopAutoRefresh clears the refreshing flag")
    func stopAutoRefreshClearsRefreshingFlag() {
        let vm = makeViewModel(databaseType: .mysql)
        vm.isRefreshing = true
        vm.stopAutoRefresh()
        #expect(!vm.isRefreshing)
    }
}
