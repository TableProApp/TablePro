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
    /// One refresh of every supported panel. A provider that can read several panels in one
    /// statement does so here; `plan` carries what it learned to the next refresh.
    func fetchSnapshot(
        plan: inout DashboardFetchPlan,
        now: ContinuousClock.Instant,
        readsEveryMetric: Bool,
        execute: (String) async throws -> QueryResult
    ) async -> DashboardSnapshot
    func killSessionSQL(processId: String) -> String?
    func cancelQuerySQL(processId: String) -> String?
    func acceptsProcessId(_ processId: String) -> Bool
}

/// One refresh's panels, each its own result, so one panel's failure leaves the others.
/// A panel the provider does not support stays nil.
struct DashboardSnapshot {
    var sessions: Result<[DashboardSession], Error>?
    var metrics: Result<[DashboardMetric], Error>?
    var slowQueries: Result<[DashboardSlowQuery], Error>?
}

/// What a dashboard keeps between refreshes for one provider. The provider is a value rebuilt when
/// the server version changes, so this lives beside it in the view model and is reset with it.
struct DashboardFetchPlan {
    /// The database size scans the whole catalog, so it is read at most this often unless every metric is asked for.
    static let slowMetricInterval: Duration = .seconds(60)

    /// Set when the server answered the single reads but refused a combined one, so later refreshes
    /// go straight to the singles and a refused metric costs only itself.
    var combinedActivityRefused = false
    var combinedSummaryRefused = false
    var slowMetricValues: [String: String] = [:]
    var slowMetricsReadAt: ContinuousClock.Instant?

    func readsSlowMetrics(at now: ContinuousClock.Instant, readsEveryMetric: Bool) -> Bool {
        guard !readsEveryMetric, let slowMetricsReadAt else { return true }
        return slowMetricsReadAt.duration(to: now) >= Self.slowMetricInterval
    }
}

extension ServerDashboardQueryProvider {
    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] { [] }
    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] { [] }
    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] { [] }
    func killSessionSQL(processId: String) -> String? { nil }
    func cancelQuerySQL(processId: String) -> String? { nil }

    func fetchSnapshot(
        plan: inout DashboardFetchPlan,
        now: ContinuousClock.Instant,
        readsEveryMetric: Bool,
        execute: (String) async throws -> QueryResult
    ) async -> DashboardSnapshot {
        var snapshot = DashboardSnapshot()
        if supportedPanels.contains(.activeSessions) {
            snapshot.sessions = await DashboardSnapshot.capture { try await fetchSessions(execute: execute) }
        }
        if supportedPanels.contains(.serverMetrics) {
            snapshot.metrics = await DashboardSnapshot.capture { try await fetchMetrics(execute: execute) }
        }
        if supportedPanels.contains(.slowQueries) {
            snapshot.slowQueries = await DashboardSnapshot.capture { try await fetchSlowQueries(execute: execute) }
        }
        return snapshot
    }

    func canKill(_ session: DashboardSession) -> Bool {
        session.canKill && killSessionSQL(processId: session.id) != nil
    }

    func canCancel(_ session: DashboardSession) -> Bool {
        session.canCancel && cancelQuerySQL(processId: session.id) != nil
    }
}

extension DashboardSnapshot {
    static func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}
