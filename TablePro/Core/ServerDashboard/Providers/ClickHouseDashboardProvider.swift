//
//  ClickHouseDashboardProvider.swift
//  TablePro
//

import Foundation

struct ClickHouseDashboardProvider: ServerDashboardQueryProvider {
    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        let sql = """
            SELECT query_id, user, current_database, elapsed, read_rows,
                   memory_usage, left(query, 1000) AS query
            FROM system.processes
            ORDER BY elapsed DESC
            """
        let result = try await execute(sql)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let elapsed = Double(value(row, at: col["elapsed"])) ?? 0
            let readRows = value(row, at: col["read_rows"])
            let memUsage = value(row, at: col["memory_usage"])
            let stateDescription = "rows: \(readRows), mem: \(formatBytes(memUsage))"
            let secs = Int(elapsed)
            return DashboardSession(
                id: value(row, at: col["query_id"]),
                user: value(row, at: col["user"]),
                database: value(row, at: col["current_database"]),
                state: stateDescription,
                durationSeconds: secs,
                duration: formatDuration(seconds: secs),
                query: value(row, at: col["query"]),
                canCancel: false
            )
        }
    }

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        var metrics: [DashboardMetric] = []

        let metricsResult = try await execute("""
            SELECT metric, value FROM system.metrics
            WHERE metric IN ('Query', 'Merge', 'PartMutation')
            """)
        let col = columnIndex(from: metricsResult.columns)
        for row in metricsResult.rows {
            let metric = value(row, at: col["metric"])
            let val = value(row, at: col["value"])
            let (label, icon) = metricDisplay(for: metric)
            metrics.append(DashboardMetric(
                id: metric.lowercased(),
                label: label,
                value: val,
                unit: "",
                icon: icon
            ))
        }

        let diskResult = try await execute("""
            SELECT formatReadableSize(sum(bytes_on_disk)) AS disk_usage
            FROM system.parts WHERE active
            """)
        if let row = diskResult.rows.first {
            metrics.append(DashboardMetric(
                id: "disk_usage",
                label: String(localized: "Disk Usage"),
                value: value(row, at: 0),
                unit: "",
                icon: "internaldrive"
            ))
        }

        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let sql = """
            SELECT user, query_duration_ms / 1000 AS duration_secs,
                   left(query, 1000) AS query
            FROM system.query_log
            WHERE type = 'QueryFinish' AND query_duration_ms > 1000
            ORDER BY event_time DESC
            LIMIT 20
            """
        let result = try await execute(sql)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let secs = Int(value(row, at: col["duration_secs"])) ?? 0
            return DashboardSlowQuery(
                duration: formatDuration(seconds: secs),
                query: value(row, at: col["query"]),
                user: value(row, at: col["user"]),
                database: ""
            )
        }
    }

    func killSessionSQL(processId: String) -> String? {
        let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        guard processId.range(of: uuidPattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return "KILL QUERY WHERE query_id = '\(processId)'"
    }
}

// MARK: - Helpers

private extension ClickHouseDashboardProvider {
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

    func formatBytes(_ string: String) -> String {
        guard let bytes = Double(string) else { return string }
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", bytes / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", bytes / 1_048_576)
        } else if bytes >= 1_024 {
            return String(format: "%.1f KB", bytes / 1_024)
        }
        return "\(Int(bytes)) B"
    }

    func metricDisplay(for metric: String) -> (String, String) {
        switch metric {
        case "Query":
            return (String(localized: "Active Queries"), "bolt.horizontal")
        case "Merge":
            return (String(localized: "Active Merges"), "arrow.triangle.merge")
        case "PartMutation":
            return (String(localized: "Part Mutations"), "gearshape.2")
        default:
            return (metric, "chart.bar")
        }
    }
}
