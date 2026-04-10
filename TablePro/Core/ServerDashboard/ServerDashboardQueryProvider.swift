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
}

extension ServerDashboardQueryProvider {
    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] { [] }
    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] { [] }
    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] { [] }
    func killSessionSQL(processId: String) -> String? { nil }
    func cancelQuerySQL(processId: String) -> String? { nil }
}
