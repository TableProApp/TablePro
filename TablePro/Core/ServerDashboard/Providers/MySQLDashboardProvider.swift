//
//  MySQLDashboardProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct MySQLDashboardProvider: ServerDashboardQueryProvider {
    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        let sql = """
            SELECT ID, USER, DB, COMMAND, TIME, STATE, LEFT(INFO, 1000) AS INFO
            FROM information_schema.PROCESSLIST
            WHERE ID <> CONNECTION_ID()
            ORDER BY TIME DESC
            """
        let result = try await execute(sql)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let secs = Int(value(row, at: col["time"])) ?? 0
            return DashboardSession(
                id: value(row, at: col["id"]),
                user: value(row, at: col["user"]),
                database: value(row, at: col["db"]),
                state: value(row, at: col["state"]),
                durationSeconds: secs,
                duration: formatDuration(seconds: secs),
                query: value(row, at: col["info"])
            )
        }
    }

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        var metrics: [DashboardMetric] = []

        let statusResult = try await execute("SHOW GLOBAL STATUS")
        var statusMap: [String: String] = [:]
        for row in statusResult.rows {
            let key = value(row, at: 0).lowercased()
            statusMap[key] = value(row, at: 1)
        }

        if let connected = statusMap["threads_connected"] {
            metrics.append(DashboardMetric(
                id: "threads_connected",
                label: String(localized: "Connected Threads"),
                value: connected,
                unit: "",
                icon: "person.2"
            ))
        }

        if let running = statusMap["threads_running"] {
            metrics.append(DashboardMetric(
                id: "threads_running",
                label: String(localized: "Running Threads"),
                value: running,
                unit: "",
                icon: "bolt.horizontal"
            ))
        }

        if let uptimeSecs = statusMap["uptime"], let secs = Int(uptimeSecs) {
            metrics.append(DashboardMetric(
                id: "uptime",
                label: String(localized: "Uptime"),
                value: formatDuration(seconds: secs),
                unit: "",
                icon: "clock"
            ))
        }

        if let questions = statusMap["questions"] {
            metrics.append(DashboardMetric(
                id: "questions",
                label: String(localized: "Total Queries"),
                value: questions,
                unit: "",
                icon: "text.magnifyingglass"
            ))
        }

        if let slow = statusMap["slow_queries"] {
            metrics.append(DashboardMetric(
                id: "slow_queries",
                label: String(localized: "Slow Queries"),
                value: slow,
                unit: "",
                icon: "tortoise"
            ))
        }

        let maxConnResult = try await execute("SELECT @@max_connections")
        if let row = maxConnResult.rows.first {
            metrics.append(DashboardMetric(
                id: "max_connections",
                label: String(localized: "Max Connections"),
                value: value(row, at: 0),
                unit: "",
                icon: "person.3"
            ))
        }

        if let received = statusMap["bytes_received"] {
            metrics.append(DashboardMetric(
                id: "bytes_received",
                label: String(localized: "Bytes Received"),
                value: formatBytes(received),
                unit: "",
                icon: "arrow.down.circle"
            ))
        }

        if let sent = statusMap["bytes_sent"] {
            metrics.append(DashboardMetric(
                id: "bytes_sent",
                label: String(localized: "Bytes Sent"),
                value: formatBytes(sent),
                unit: "",
                icon: "arrow.up.circle"
            ))
        }

        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let sql = """
            SELECT ID, USER, DB, TIME, LEFT(INFO, 1000) AS INFO
            FROM information_schema.PROCESSLIST
            WHERE COMMAND <> 'Sleep' AND TIME > 1 AND ID <> CONNECTION_ID()
            ORDER BY TIME DESC
            """
        let result = try await execute(sql)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let secs = Int(value(row, at: col["time"])) ?? 0
            return DashboardSlowQuery(
                duration: formatDuration(seconds: secs),
                query: value(row, at: col["info"]),
                user: value(row, at: col["user"]),
                database: value(row, at: col["db"])
            )
        }
    }

    func killSessionSQL(processId: String) -> String? {
        guard let id = Int(processId) else { return nil }
        return "KILL \(id)"
    }

    func cancelQuerySQL(processId: String) -> String? {
        guard let id = Int(processId) else { return nil }
        return "KILL QUERY \(id)"
    }
}

// MARK: - Helpers

private extension MySQLDashboardProvider {
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
}
