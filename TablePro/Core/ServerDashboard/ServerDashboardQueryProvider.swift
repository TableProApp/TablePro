//
//  ServerDashboardQueryProvider.swift
//  TablePro
//

import Foundation

/// Provides database-specific queries and result parsing for the server dashboard.
protocol ServerDashboardQueryProvider {
    var supportedPanels: Set<DashboardPanel> { get }
    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession]
    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric]
    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery]
    func killSessionSQL(processId: String) -> String?
    func cancelQuerySQL(processId: String) -> String?
    func acceptsProcessId(_ processId: String) -> Bool
}

extension ServerDashboardQueryProvider {
    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] { [] }
    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] { [] }
    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] { [] }
    func killSessionSQL(processId: String) -> String? { nil }
    func cancelQuerySQL(processId: String) -> String? { nil }

    func canKill(_ session: DashboardSession) -> Bool {
        session.canKill && killSessionSQL(processId: session.id) != nil
    }

    func canCancel(_ session: DashboardSession) -> Bool {
        session.canCancel && cancelQuerySQL(processId: session.id) != nil
    }
}
