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
        activityCatalog: PostgreSQLActivityCatalog = .current,
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
                    "Metric \(definition.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
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

    func killSessionSQL(processId: String) -> String? {
        guard let pid = Int(processId) else { return nil }
        return "SELECT pg_terminate_backend(\(pid))"
    }

    func cancelQuerySQL(processId: String) -> String? {
        guard let pid = Int(processId) else { return nil }
        return "SELECT pg_cancel_backend(\(pid))"
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
                    SELECT CASE WHEN blks_hit + blks_read = 0 THEN '0'
                                ELSE round(blks_hit::numeric / (blks_hit + blks_read) * 100, 1)::text
                           END
                    FROM pg_stat_database WHERE datname = current_database()
                    """
            ),
            MetricDefinition(
                id: "db_size",
                label: String(localized: "Database Size"),
                unit: "",
                icon: "internaldrive",
                query: "SELECT pg_size_pretty(pg_database_size(current_database()))"
            ),
            MetricDefinition(
                id: "uptime",
                label: String(localized: "Uptime"),
                unit: "",
                icon: "clock",
                query: "SELECT date_trunc('second', now() - pg_postmaster_start_time())::text"
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
