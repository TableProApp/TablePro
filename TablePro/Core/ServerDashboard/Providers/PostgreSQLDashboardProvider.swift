//
//  PostgreSQLDashboardProvider.swift
//  TablePro
//

import Foundation

struct PostgreSQLDashboardProvider: ServerDashboardQueryProvider {
    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        let sql = """
            SELECT pid, usename, datname, state,
                   EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs,
                   left(query, 1000) AS query
            FROM pg_stat_activity
            WHERE pid <> pg_backend_pid()
              AND backend_type = 'client backend'
            ORDER BY query_start NULLS LAST
            """
        let result = try await execute(sql)
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

        let connections = try await execute("SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'")
        if let row = connections.rows.first {
            metrics.append(DashboardMetric(
                id: "connections",
                label: String(localized: "Connections"),
                value: value(row, at: 0),
                unit: "",
                icon: "person.2"
            ))
        }

        let cacheHit = try await execute("""
            SELECT CASE WHEN blks_hit + blks_read = 0 THEN '0'
                        ELSE round(blks_hit::numeric / (blks_hit + blks_read) * 100, 1)::text
                   END
            FROM pg_stat_database WHERE datname = current_database()
            """)
        if let row = cacheHit.rows.first {
            metrics.append(DashboardMetric(
                id: "cache_hit",
                label: String(localized: "Cache Hit Ratio"),
                value: value(row, at: 0),
                unit: "%",
                icon: "bolt"
            ))
        }

        let dbSize = try await execute("SELECT pg_size_pretty(pg_database_size(current_database()))")
        if let row = dbSize.rows.first {
            metrics.append(DashboardMetric(
                id: "db_size",
                label: String(localized: "Database Size"),
                value: value(row, at: 0),
                unit: "",
                icon: "internaldrive"
            ))
        }

        let uptime = try await execute(
            "SELECT date_trunc('second', now() - pg_postmaster_start_time())::text"
        )
        if let row = uptime.rows.first {
            metrics.append(DashboardMetric(
                id: "uptime",
                label: String(localized: "Uptime"),
                value: value(row, at: 0),
                unit: "",
                icon: "clock"
            ))
        }

        let activeQueries = try await execute("""
            SELECT count(*) FROM pg_stat_activity
            WHERE state = 'active' AND pid <> pg_backend_pid()
            """)
        if let row = activeQueries.rows.first {
            metrics.append(DashboardMetric(
                id: "active_queries",
                label: String(localized: "Active Queries"),
                value: value(row, at: 0),
                unit: "",
                icon: "bolt.horizontal"
            ))
        }

        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let sql = """
            SELECT pid, usename, datname,
                   EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs,
                   left(query, 1000) AS query
            FROM pg_stat_activity
            WHERE state = 'active'
              AND now() - query_start > interval '1 second'
              AND pid <> pg_backend_pid()
            ORDER BY query_start
            """
        let result = try await execute(sql)
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

// MARK: - Helpers

private extension PostgreSQLDashboardProvider {
    func columnIndex(from columns: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, name) in columns.enumerated() {
            map[name.lowercased()] = index
        }
        return map
    }

    func value(_ row: [String?], at index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index] ?? ""
    }

    func formatDuration(seconds: Int) -> String {
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        } else if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }
}
