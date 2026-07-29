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
    private func makeViewModel(databaseType: DatabaseType) -> ServerDashboardViewModel {
        ServerDashboardViewModel(connectionId: UUID(), databaseType: databaseType, services: .live)
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
    func mySQLKillAndCancelCapabilities() {
        let vm = makeViewModel(databaseType: .mysql)
        #expect(vm.canKillSessions)
        #expect(vm.canCancelQueries)
    }

    @Test("MSSQL supports kill session but not cancel query")
    func mssqlKillButNoCancel() {
        let vm = makeViewModel(databaseType: .mssql)
        #expect(vm.canKillSessions)
        #expect(!vm.canCancelQueries)
    }

    @Test("ClickHouse supports neither kill nor cancel")
    func clickHouseHasNoActions() {
        let vm = makeViewModel(databaseType: .clickhouse)
        #expect(!vm.canKillSessions)
        #expect(!vm.canCancelQueries)
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
