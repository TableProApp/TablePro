//
//  PostgreSQLDashboardProvider.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

struct PostgreSQLDashboardProvider: ServerDashboardQueryProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PostgreSQLDashboardProvider")

    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]
    let activityCatalog: PostgreSQLActivityCatalog
    let metricSet: PostgreSQLDashboardMetricSet

    init(
        activityCatalog: PostgreSQLActivityCatalog,
        metricSet: PostgreSQLDashboardMetricSet = .full
    ) {
        self.activityCatalog = activityCatalog
        self.metricSet = metricSet
    }

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        let result = try await execute(activityCatalog.sessionsQuery)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let pid = value(row, at: col["pid"])
            let secs = Int(value(row, at: col["duration_secs"])) ?? 0
            return DashboardSession(
                id: pid,
                user: value(row, at: col["usename"]),
                database: value(row, at: col["datname"]),
                state: value(row, at: col["state"]),
                durationSeconds: secs,
                duration: formatDuration(seconds: secs),
                query: value(row, at: col["query"])
            )
        }
    }

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        var metrics: [DashboardMetric] = []
        var firstFailure: Error?

        for definition in metricDefinitions {
            do {
                let result = try await execute(definition.query)
                guard let row = result.rows.first else { continue }
                metrics.append(DashboardMetric(
                    id: definition.id,
                    label: definition.label,
                    value: value(row, at: 0),
                    unit: definition.unit,
                    icon: definition.icon
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.warning(
                    "Metric \(definition.id, privacy: .public) failed: \(error.publicLogShape, privacy: .public)"
                )
                if firstFailure == nil { firstFailure = error }
            }
        }

        if metrics.isEmpty, let firstFailure {
            throw firstFailure
        }
        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let result = try await execute(activityCatalog.slowQueriesQuery)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let secs = Int(value(row, at: col["duration_secs"])) ?? 0
            return DashboardSlowQuery(
                duration: formatDuration(seconds: secs),
                query: value(row, at: col["query"]),
                user: value(row, at: col["usename"]),
                database: value(row, at: col["datname"])
            )
        }
    }

    /// Two statements a refresh where the singles take seven: one read of `pg_stat_activity` for the
    /// sessions, the slow queries and both counts, and one for the cache hit ratio and the uptime. The
    /// database size is read once a minute and on Refresh Now. A combined read the server refuses
    /// falls back to the singles for its panels, and when the singles answer, later refreshes skip it.
    func fetchSnapshot(
        plan: inout DashboardFetchPlan,
        now: ContinuousClock.Instant,
        readsEveryMetric: Bool,
        execute: (String) async throws -> QueryResult
    ) async -> DashboardSnapshot {
        do {
            return try await snapshot(plan: &plan, now: now, readsEveryMetric: readsEveryMetric, execute: execute)
        } catch {
            return DashboardSnapshot(sessions: .failure(error), metrics: .failure(error), slowQueries: .failure(error))
        }
    }

    // Throws only a cancellation; every other failure lands in its panel.
    private func snapshot(
        plan: inout DashboardFetchPlan,
        now: ContinuousClock.Instant,
        readsEveryMetric: Bool,
        execute: (String) async throws -> QueryResult
    ) async throws -> DashboardSnapshot {
        var result = DashboardSnapshot()
        var activity: PostgreSQLActivity?
        if !plan.combinedActivityRefused {
            do {
                activity = PostgreSQLActivity(try await execute(activityCatalog.activityQuery))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.warning("Combined activity read failed: \(error.publicLogShape, privacy: .public)")
            }
        }

        if let activity {
            result.sessions = .success(activity.sessions)
            result.slowQueries = .success(activity.slowQueries)
        } else {
            result.sessions = try await Self.captureFailure { try await fetchSessions(execute: execute) }
            result.slowQueries = try await Self.captureFailure { try await fetchSlowQueries(execute: execute) }
            if !plan.combinedActivityRefused, case .success = result.sessions {
                plan.combinedActivityRefused = true
            }
        }

        result.metrics = try await metrics(
            activity: activity,
            plan: &plan,
            now: now,
            readsEveryMetric: readsEveryMetric,
            execute: execute
        )
        return result
    }

    private func metrics(
        activity: PostgreSQLActivity?,
        plan: inout DashboardFetchPlan,
        now: ContinuousClock.Instant,
        readsEveryMetric: Bool,
        execute: (String) async throws -> QueryResult
    ) async throws -> Result<[DashboardMetric], Error> {
        let definitions = metricDefinitions
        let summaryIds = definitions.map(\.id).filter { Self.summaryMetricIds.contains($0) }
        var summary: [String: String]?
        var summaryReadFailed = false
        if !summaryIds.isEmpty, !plan.combinedSummaryRefused {
            do {
                summary = try await readSummary(execute: execute)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                summaryReadFailed = true
                Self.logger.warning("Combined metric read failed: \(error.publicLogShape, privacy: .public)")
            }
        }

        let readsSlowMetrics = plan.readsSlowMetrics(at: now, readsEveryMetric: readsEveryMetric)
        if readsSlowMetrics {
            plan.slowMetricsReadAt = now
        }

        var metrics: [DashboardMetric] = []
        var firstFailure: Error?
        var singleSummaryAnswered = false
        for definition in definitions {
            let value: String?
            if let activity, let counted = activity.count(for: definition.id) {
                value = String(counted)
            } else if let summary, Self.summaryMetricIds.contains(definition.id) {
                value = summary[definition.id]
            } else if Self.slowMetricIds.contains(definition.id), !readsSlowMetrics {
                value = plan.slowMetricValues[definition.id]
            } else {
                do {
                    let read = try await execute(definition.query)
                    value = read.rows.first.map { self.value($0, at: 0) }
                    if Self.summaryMetricIds.contains(definition.id) {
                        singleSummaryAnswered = true
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Self.logger.warning(
                        "Metric \(definition.id, privacy: .public) failed: \(error.publicLogShape, privacy: .public)"
                    )
                    if firstFailure == nil { firstFailure = error }
                    value = nil
                }
                if Self.slowMetricIds.contains(definition.id) {
                    plan.slowMetricValues[definition.id] = value
                }
            }
            guard let value else { continue }
            metrics.append(DashboardMetric(
                id: definition.id,
                label: definition.label,
                value: value,
                unit: definition.unit,
                icon: definition.icon
            ))
        }

        if summaryReadFailed, singleSummaryAnswered {
            plan.combinedSummaryRefused = true
        }
        if metrics.isEmpty, let firstFailure {
            return .failure(firstFailure)
        }
        return .success(metrics)
    }

    private static let summaryMetricIds: Set<String> = ["cache_hit", "uptime"]
    private static let slowMetricIds: Set<String> = ["db_size"]

    // A server with no row for this database has no cache hit ratio, as the single read returns no row.
    private func readSummary(execute: (String) async throws -> QueryResult) async throws -> [String: String] {
        let definitions = Dictionary(uniqueKeysWithValues: metricDefinitions.map { ($0.id, $0) })
        let columns = Self.summaryMetricIds.sorted().compactMap { id -> String? in
            guard let definition = definitions[id] else { return nil }
            return "(\(definition.query)) AS \(id)"
        }
        let read = try await execute("SELECT " + columns.joined(separator: ", "))
        guard let row = read.rows.first else { return [:] }
        let index = columnIndex(from: read.columns)
        var values: [String: String] = [:]
        for id in Self.summaryMetricIds {
            guard let position = index[id], position < row.count, let text = row[position].asText else { continue }
            values[id] = text
        }
        return values
    }

    private static func captureFailure<T>(_ body: () async throws -> T) async throws -> Result<T, Error> {
        do {
            return .success(try await body())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error)
        }
    }

    func killSessionSQL(processId: String) -> String? {
        guard acceptsProcessId(processId), let pid = Int(processId) else { return nil }
        return "SELECT pg_catalog.pg_terminate_backend(\(pid))"
    }

    func cancelQuerySQL(processId: String) -> String? {
        guard acceptsProcessId(processId), let pid = Int(processId) else { return nil }
        return "SELECT pg_catalog.pg_cancel_backend(\(pid))"
    }

    func acceptsProcessId(_ processId: String) -> Bool {
        Int(processId) != nil
    }
}

// MARK: - Combined Activity

/// The rows of `PostgreSQLActivityCatalog.activityQuery`, filtered the way each single query filters.
struct PostgreSQLActivity {
    let sessions: [DashboardSession]
    let slowQueries: [DashboardSlowQuery]
    let connectionCount: Int
    let activeCount: Int

    init(_ result: QueryResult) {
        var index: [String: Int] = [:]
        for (position, name) in result.columns.enumerated() {
            index[name.lowercased()] = position
        }
        func text(_ row: [PluginCellValue], _ column: String) -> String {
            guard let position = index[column], position < row.count else { return "" }
            return row[position].asText ?? ""
        }
        func flag(_ row: [PluginCellValue], _ column: String) -> Bool {
            text(row, column) == "1"
        }

        var sessions: [DashboardSession] = []
        var slowQueries: [DashboardSlowQuery] = []
        var connectionCount = 0
        var activeCount = 0
        for row in result.rows {
            let isOwn = flag(row, "is_own")
            let isClient = flag(row, "is_client")
            let seconds = Int(text(row, "duration_secs")) ?? 0
            let duration = DurationFormatting.string(seconds: seconds)
            if isClient {
                connectionCount += 1
            }
            if isOwn {
                continue
            }
            if flag(row, "is_active") {
                activeCount += 1
            }
            if isClient {
                sessions.append(DashboardSession(
                    id: text(row, "pid"),
                    user: text(row, "usename"),
                    database: text(row, "datname"),
                    state: text(row, "state"),
                    durationSeconds: seconds,
                    duration: duration,
                    query: text(row, "query")
                ))
            }
            if flag(row, "is_slow") {
                slowQueries.append(DashboardSlowQuery(
                    duration: duration,
                    query: text(row, "query"),
                    user: text(row, "usename"),
                    database: text(row, "datname")
                ))
            }
        }
        self.sessions = sessions
        self.slowQueries = slowQueries
        self.connectionCount = connectionCount
        self.activeCount = activeCount
    }

    func count(for metricId: String) -> Int? {
        switch metricId {
        case "connections": return connectionCount
        case "active_queries": return activeCount
        default: return nil
        }
    }
}

// MARK: - Metrics

private extension PostgreSQLDashboardProvider {
    struct MetricDefinition {
        let id: String
        let label: String
        let unit: String
        let icon: String
        let query: String
    }

    var metricDefinitions: [MetricDefinition] {
        allMetricDefinitions.filter { metricSet.identifiers.contains($0.id) }
    }

    var allMetricDefinitions: [MetricDefinition] {
        [
            MetricDefinition(
                id: "connections",
                label: String(localized: "Connections"),
                unit: "",
                icon: "person.2",
                query: activityCatalog.connectionCountQuery
            ),
            MetricDefinition(
                id: "cache_hit",
                label: String(localized: "Cache Hit Ratio"),
                unit: "%",
                icon: "bolt",
                query: """
                    SELECT CASE WHEN (blks_hit OPERATOR(pg_catalog.+) blks_read) OPERATOR(pg_catalog.=) 0 THEN '0'
                                ELSE pg_catalog.round(
                                    blks_hit::pg_catalog.numeric
                                        OPERATOR(pg_catalog./) (blks_hit OPERATOR(pg_catalog.+) blks_read)::pg_catalog.numeric
                                        OPERATOR(pg_catalog.*) 100.0,
                                    1
                                )::pg_catalog.text
                           END
                    FROM pg_catalog.pg_stat_database
                    WHERE datname OPERATOR(pg_catalog.=) pg_catalog.current_database()
                    """
            ),
            MetricDefinition(
                id: "db_size",
                label: String(localized: "Database Size"),
                unit: "",
                icon: "internaldrive",
                query: "SELECT pg_catalog.pg_size_pretty(pg_catalog.pg_database_size(pg_catalog.current_database()))"
            ),
            MetricDefinition(
                id: "uptime",
                label: String(localized: "Uptime"),
                unit: "",
                icon: "clock",
                // KingbaseES in Oracle mode subtracts timestamps into an Oracle interval, printed as +000000000 00:20:19.
                query: """
                    SELECT pg_catalog.date_trunc(
                        'second',
                        CAST(pg_catalog.now() OPERATOR(pg_catalog.-) pg_catalog.pg_postmaster_start_time() AS pg_catalog.interval)
                    )::pg_catalog.text
                    """
            ),
            MetricDefinition(
                id: "active_queries",
                label: String(localized: "Active Queries"),
                unit: "",
                icon: "bolt.horizontal",
                query: activityCatalog.activeQueryCountQuery
            )
        ]
    }
}

// MARK: - Helpers

private extension PostgreSQLDashboardProvider {
    func columnIndex(from columns: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, name) in columns.enumerated() {
            map[name.lowercased()] = index
        }
        return map
    }

    func value(_ row: [PluginCellValue], at index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index].asText ?? ""
    }

    func formatDuration(seconds: Int) -> String {
        DurationFormatting.string(seconds: seconds)
    }
}
